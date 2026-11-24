import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib", "tools"))
import honeydew_strategist as hs

def test_ada_trading_classification_and_fallback():
    prompt = "Congratulations George! Your ADA order completed both legs, you made +3.445 ADA total!! Now, let us dig back in. You have 150 ADA, what is your play"
    cls = hs.classify_task(prompt)
    assert cls == "research"
    plan = hs.fallback_heuristic_plan(prompt)
    assert len(plan) == 3
    assert plan[0]["task_type"] == "research"
    assert "DEX" in plan[0]["task"] or "prices" in plan[0]["task"]
    assert "vitals" not in plan[0]["task"].lower()
    assert "git" not in plan[1]["task"].lower()

def test_chat_classification():
    prompt = "thanks George, great job!"
    cls = hs.classify_task(prompt)
    assert cls == "chat"
    plan = hs.fallback_heuristic_plan(prompt)
    assert len(plan) == 1
    assert plan[0]["task_type"] == "chat"

def test_code_classification():
    prompt = "please fix the bug in lib/core/react.sh where the process crashes"
    cls = hs.classify_task(prompt)
    assert cls == "code"

def test_ops_classification():
    prompt = "run a sweep of the cron jobs and check system vitals"
    cls = hs.classify_task(prompt)
    assert cls == "ops"

def test_grammar_loader():
    g = hs._load_grammar()
    assert g is not None
    assert "root" in g
    assert "task_type" in g


def test_dedupe_items_trailing_echo():
    # Steps 4-6 verbatim echo of Steps 1-3
    dup = [
        {"id": 1, "task": "Research historical NFL disciplinary actions for domestic violence cases", "tier": 1, "depends_on": []},
        {"id": 2, "task": "Analyze the NFL's Personal Conduct Policy precedents for suspension lengths", "tier": 2, "depends_on": [1]},
        {"id": 3, "task": "Synthesize and present a prediction of the likely NFL response", "tier": 3, "depends_on": [2]},
        {"id": 4, "task": "Research historical NFL disciplinary actions for domestic violence cases", "tier": 4, "depends_on": [3]},
        {"id": 5, "task": "Analyze the NFL's Personal Conduct Policy precedents for suspension lengths", "tier": 5, "depends_on": [4]},
        {"id": 6, "task": "Synthesize and present a prediction of the likely NFL response", "tier": 6, "depends_on": [5]},
    ]
    out = hs._dedupe_items(dup)
    assert [i["id"] for i in out] == [1, 2, 3]
    assert [i["depends_on"] for i in out] == [[], [1], [2]]
    assert [i["tier"] for i in out] == [1, 2, 3]


def test_dedupe_items_mid_plan_duplicate_remaps_downstream_deps():
    # Step 2 is a duplicate of Step 1; Step 3 (orig id 3) depends on [2]; Step 4 (orig id 4) depends on [3]
    mid_dup = [
        {"id": 1, "task": "Investigate honeydew list creation logic flaw in strategist", "tier": 1, "depends_on": []},
        {"id": 2, "task": "Investigate honeydew list creation logic flaw in strategist", "tier": 2, "depends_on": [1]},
        {"id": 3, "task": "Fix the step duplication bug in the honeydew list creation process", "tier": 3, "depends_on": [2]},
        {"id": 4, "task": "Synthesize and present the root causes and applied fixes", "tier": 4, "depends_on": [3]},
    ]
    out = hs._dedupe_items(mid_dup)
    assert [i["id"] for i in out] == [1, 2, 3]
    assert out[0]["depends_on"] == []
    assert out[1]["depends_on"] == [1]
    assert out[2]["depends_on"] == [2]  # orig 3 mapped to new_id 2, not dropped as self-dep!
    assert [i["tier"] for i in out] == [1, 2, 3]


def _pr_review_prompt():
    # Canonical dispatch header built by lib/agents/pr.sh pr_review()
    return """Conduct a formal 1-Reviewer Acceptance Review for Pull Request 545 ('chore(drift): promote uncommitted agent changes in wi_election_hourly.sh', branch 'drift/auto_20261103_100402_28737e56' -> 'develop').
PR Index: 545

Diffstat:
 .george/cron_jobs/wi_election_hourly.sh | 145 ++++

Instructions:
1. Use your pr_reviewer tools.
3. Submit your review on the PR by calling gitea_pr_review with index=545.
5. Budget discipline: keep your plan to at most 2 milestones (inspect+verify -> submit).
"""


def test_pr_review_task_detection():
    assert hs.is_pr_review_task(_pr_review_prompt()) is True
    # Uppercase variant also detected (case-insensitive)
    assert hs.is_pr_review_task("CONDUCT A FORMAL 1-REVIEWER ACCEPTANCE REVIEW FOR PULL REQUEST 545") is True
    # Bare 'acceptance review' without the reviewer qualifier must NOT trigger
    assert hs.is_pr_review_task("please write an acceptance review of the pull request") is False
    # Non-review tasks must never match
    assert hs.is_pr_review_task("please fix the bug in lib/core/react.sh") is False
    assert hs.is_pr_review_task("run a sweep of the cron jobs and check system vitals") is False
    assert hs.is_pr_review_task("Conduct a security audit of the cron table") is False


def test_pr_review_plan_shape_and_budget():
    plan = hs.pr_review_plan(_pr_review_prompt())
    # Deterministic 2-milestone DAG (inspect+verify -> submit) with explicit
    # milestone_complete discipline; PR_REVIEW_MAX_TURNS defaults to 200.
    assert len(plan) == 2
    assert plan[0]["task_type"] == "code"
    assert plan[1]["task_type"] == "code"
    assert plan[0]["depends_on"] == []
    assert plan[1]["depends_on"] == [1]
    # Step 1 must NOT submit; Step 2 submits and forbids duplicate posts
    assert "gitea_pr_review" not in plan[0]["task"]
    assert "gitea_pr_review" in plan[1]["task"]
    assert "never post a duplicate" in plan[1]["task"]
    assert "VERDICT" in plan[1]["task"]


def test_pr_review_fallback_planner_short_circuit():
    plan = hs.fallback_heuristic_plan(_pr_review_prompt())
    assert len(plan) == 2
    assert plan[0]["task_type"] == "code"
    assert plan[1]["task_type"] == "code"
    assert "gitea_pr_review" in plan[1]["task"]


def test_pr_review_main_cli_short_circuit(monkeypatch, capsys):
    # main() must emit the deterministic plan BEFORE touching the LLM strategist endpoint
    def boom(task, endpoint_url):
        raise AssertionError("LLM strategist endpoint must not be consulted for PR reviews")
    monkeypatch.setattr(hs, "query_strategist_endpoint", boom)
    monkeypatch.setattr(sys, "argv", ["honeydew_strategist.py", _pr_review_prompt(), "http://127.0.0.1:1"])
    hs.main()
    import json as _json
    out = _json.loads(capsys.readouterr().out)
    assert out["task_type"] == "code"
    assert out["source"] == "deterministic-pr-review"
    assert len(out["items"]) == 2
