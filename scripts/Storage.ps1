function Complete-LetheFileWrite([string]$temporaryPath,[string]$destinationPath) {
    # PowerShell converts $null to an empty string for a System.String parameter.
    # File.Replace requires a real null to omit the backup filename on .NET Framework.
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        [IO.File]::Replace($temporaryPath,$destinationPath,[NullString]::Value)
    } else {
        [IO.File]::Move($temporaryPath,$destinationPath)
    }
}
