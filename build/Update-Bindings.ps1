$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=New-Object 'System.Collections.Generic.List[string]'
$lines.Add('<?xml version="1.0" encoding="utf-8"?>')
$lines.Add('<configuration><startup useLegacyV2RuntimeActivationPolicy="true"><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8" /></startup>')
$lines.Add('<runtime><assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1"><probing privatePath="lib" />')
foreach($file in Get-ChildItem (Join-Path $root 'lib') -Filter '*.dll' | Sort-Object Name){
    $identity=[Reflection.AssemblyName]::GetAssemblyName($file.FullName)
    $token=([BitConverter]::ToString($identity.GetPublicKeyToken())).Replace('-','').ToLowerInvariant()
    if(-not $token){continue}
    $version=$identity.Version.ToString()
    $lines.Add(('<dependentAssembly><assemblyIdentity name="{0}" publicKeyToken="{1}" culture="neutral" /><bindingRedirect oldVersion="0.0.0.0-{2}" newVersion="{2}" /></dependentAssembly>' -f $identity.Name,$token,$version))
}
$lines.Add('</assemblyBinding></runtime></configuration>')
[IO.File]::WriteAllLines((Join-Path $root 'LETHE.exe.config'),$lines,[Text.UTF8Encoding]::new($false))
