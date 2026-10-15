$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$assemblies=@{}
foreach($file in Get-ChildItem (Join-Path $root 'lib') -Filter '*.dll'){
    $name=[Reflection.AssemblyName]::GetAssemblyName($file.FullName)
    $assemblies[$name.Name]=@{Identity=$name;Path=$file.FullName}
}
[xml]$config=Get-Content (Join-Path $root 'LETHE.exe.config') -Raw
$bindings=$config.configuration.runtime.assemblyBinding
if($bindings.probing.privatePath -ne 'lib'){throw 'Missing application probing path'}
$count=0
foreach($entry in $assemblies.Values){
    if($PSVersionTable.PSEdition -eq 'Core'){$assembly=[Reflection.Assembly]::LoadFile($entry.Path)}
    else{$assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($entry.Path)}
    foreach($reference in $assembly.GetReferencedAssemblies()){
        if(-not $assemblies.ContainsKey($reference.Name)){continue}
        $available=$assemblies[$reference.Name].Identity
        if($reference.Version -gt $available.Version){throw ('Bundled dependency older than required: '+$reference.Name)}
        if($reference.Version -ne $available.Version){
            $redirect=@($bindings.dependentAssembly | Where-Object {$_.assemblyIdentity.name -eq $reference.Name})
            if($redirect.Count -ne 1 -or $redirect[0].bindingRedirect.newVersion -ne $available.Version.ToString()){throw ('Missing redirect for '+$reference.Name)}
        }
        $count++
    }
}
Write-Host ('PASS: '+$count+' bundled assembly references and EXE binding redirects.')
