param([Parameter(Mandatory)][string]$Roots)
# Parse every .ps1 under the comma-separated folders; print each syntax error; exit with the number of bad files.
$bad = 0
foreach ($root in ($Roots -split ',')) {
    Get-ChildItem -Path $root -Recurse -Filter *.ps1 | ForEach-Object {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
        if ($errs) {
            $bad++
            $errs | ForEach-Object { '{0}:{1} {2}' -f $_.Extent.File, $_.Extent.StartLineNumber, $_.Message }
        }
    }
}
exit $bad
