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
