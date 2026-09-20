import re, sys, os

target_file = os.path.join(os.path.dirname(__file__), "..", "lib", "remote.sh")
target_file = os.path.abspath(target_file)

if not os.path.exists(target_file):
    print(f"Target file not found: {target_file}")
    sys.exit(0)

with open(target_file, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

patterns = {
    "unquoted_var_in_cmd": r"\$\w+\b[^\"\'\s]+",
    "eval_of_remote_output": r"eval\(.*_remote_.*\)",
    "subshell_of_remote_output": r"\$\((?:_remote_)[^)]+\)",
    "heredoc_with_unquoted_var": r"<<\s*\|\|\s*\$[a-zA-Z0-9_]+",
    "system_with_remote_output": r"system\(.*_remote_.*\)",
    "exec_with_remote_output": r"exec\(.*_remote_.*\)",
    "echo_of_remote_output": r"echo\s+.*_remote_.*",
}

findings = []
for name, pat in patterns.items():
    for i, line in enumerate(lines):
        if re.search(pat, line):
            findings.append((name, i + 1, line.strip()))

report_path = os.path.join(os.path.dirname(__file__), "..", "SECURITY_INSPECTION.md")
report_path = os.path.abspath(report_path)

with open(report_path, "w", encoding="utf-8") as rf:
    rf.write(f"# Security Audit: lib/remote.sh Shell Injection Analysis\n\n")
    rf.write(f"Analyzed {len(lines)} lines from `lib/remote.sh`.\n\n")
    rf.write(f"### Scanner Findings ({len(findings)} matches):\n\n")
    if findings:
        rf.write("| Pattern Name | Line | Code Snippet |\n|---|---|---|\n")
        for name, lno, snippet in findings:
            clean_snip = snippet.replace("|", "\\|")
            rf.write(f"| `{name}` | {lno} | `{clean_snip}` |\n")
    else:
        rf.write("No severe unquoted variable injections detected in active execution paths.\n")

print(f"Audit completed: {len(findings)} patterns flagged. Report written to SECURITY_INSPECTION.md")
