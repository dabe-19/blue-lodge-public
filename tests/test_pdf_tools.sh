#!/bin/bash
# ── Tests: PDF Tooling & Sovereign Text Extraction ───────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/native_tools.sh"
source "$LODGE_DIR/commands/pdf.sh"
source "$LODGE_DIR/commands/read.sh"

test_start "PDF Extraction & Native Tooling (Poppler pdftotext)"

TMP_PDF_DIR=$(test_tmpdir)
SAMPLE_PDF="$TMP_PDF_DIR/test_document.pdf"

# Generate a minimal valid PDF containing text
python3 -c "
pdf = b'''%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj
4 0 obj
<< /Length 44 >>
stream
BT
/F1 24 Tf
100 700 Td
(Hello Blue Lodge PDF) Tj
ET
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 6
0000000000 65535 f 
0000000010 00000 n 
0000000060 00000 n 
0000000117 00000 n 
0000000234 00000 n 
0000000327 00000 n 
trailer
<< /Size 6 /Root 1 0 R >>
startxref
407
%%EOF
'''
open('$SAMPLE_PDF', 'wb').write(pdf)
"

describe "tools_read_pdf (lib/tools.sh)"

  it "errors cleanly on nonexistent file" && {
    out=$(tools_read_pdf "$TMP_PDF_DIR/missing.pdf" 2>&1)
    rc=$?
    assert_neq "$rc" "0"
    assert_contains "$out" "not found"
  }

  it "extracts text from valid PDF with page headers" && {
    out=$(tools_read_pdf "$SAMPLE_PDF" 2>&1)
    assert_ok $?
    assert_contains "$out" "Hello Blue Lodge PDF"
    assert_contains "$out" "--- start of"
  }

  it "supports page range parameters" && {
    out=$(tools_read_pdf "$SAMPLE_PDF" 1 1 2>&1)
    assert_ok $?
    assert_contains "$out" "Hello Blue Lodge PDF"
  }

describe "Transparent PDF routing in tools_read_file"

  it "auto-routes .pdf extensions to PDF reader" && {
    out=$(tools_read_file "$SAMPLE_PDF" 2>&1)
    assert_ok $?
    assert_contains "$out" "Hello Blue Lodge PDF"
  }

describe "Native Tool Bridge: pdf_read and file_read"

  it "dispatches pdf_read native tool successfully" && {
    res=$(native_tools_dispatch "call_pdf_1" "pdf_read" "{\"path\":\"$SAMPLE_PDF\"}" "$TMP_PDF_DIR")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    assert_eq "$role" "tool"
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Hello Blue Lodge PDF"
  }

  it "dispatches file_read native tool transparently on PDF" && {
    res=$(native_tools_dispatch "call_fr_pdf" "file_read" "{\"path\":\"$SAMPLE_PDF\"}" "$TMP_PDF_DIR")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Hello Blue Lodge PDF"
  }

describe "Slash Commands: /pdf and /read"

  it "executes /pdf slash command on valid PDF" && {
    out=$(cmd_pdf "$SAMPLE_PDF" "$TMP_PDF_DIR" 2>&1)
    assert_ok $?
    assert_contains "$out" "Hello Blue Lodge PDF"
  }

  it "executes /pdf with missing file cleanly" && {
    out=$(cmd_pdf "$TMP_PDF_DIR/no_such.pdf" "$TMP_PDF_DIR" 2>&1)
    rc=$?
    assert_neq "$rc" "0"
    assert_contains "$out" "not found"
  }

  it "executes /read on .pdf files transparently" && {
    out=$(cmd_read "$SAMPLE_PDF" "$TMP_PDF_DIR" 2>&1)
    assert_ok $?
    assert_contains "$out" "Hello Blue Lodge PDF"
  }

rm -rf "$TMP_PDF_DIR"
test_end
