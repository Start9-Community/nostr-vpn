$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'desktop-windows-underlay-change-e2e.ps1'),
  [ref]$tokens, [ref]$errors
)
if ($errors) { throw ($errors | Out-String) }
$predicate = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Test-ExpectedFipsCoreVersion'
}, $false)
if (!$predicate) { throw 'Runtime predicate missing' }
. ([ScriptBlock]::Create($predicate.Extent.Text))
$ExpectedFipsVersion = '0.4.107'
$ExpectedFipsRevision = '0123456789'
$cases = @(
  @{ proof = '0.4.107'; actual = '0.4.107'; expected = $true },
  @{ proof = '0.4.107 (rev 0123456789)'; actual = '0.4.107 (rev 0123456789)'; expected = $true },
  @{ proof = ''; actual = '0.4.107'; expected = $false },
  @{ proof = '0.4.106'; actual = '0.4.106'; expected = $false },
  @{ proof = '0.4.107 (rev aaaaaaaaaa)'; actual = '0.4.107 (rev aaaaaaaaaa)'; expected = $false },
  @{ proof = '0.4.107'; actual = '0.4.107 (rev aaaaaaaaaa)'; expected = $false },
  @{ proof = '0.4.107'; actual = '0.4.107 (rev 0123456789-dirty)'; expected = $false },
  @{ proof = '0.4.107 (rev 0123456789)'; actual = '0.4.107'; expected = $false }
)
foreach ($case in $cases) {
  $VerifiedFipsRuntimeVersion = $case.proof
  if ((Test-ExpectedFipsCoreVersion $case.actual) -ne $case.expected) {
    throw "Runtime predicate mismatch: $($case | ConvertTo-Json -Compress)"
  }
}
Write-Output 'WINDOWS_RUNTIME_PROVENANCE_PREDICATE_OK cases=8'
