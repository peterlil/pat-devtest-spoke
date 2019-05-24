param (
    $dtap,
    $sourcePath,
    $SourceVersion,
    $WhatIf
)

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @("  " * $Depth + $_.Code + ": " + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

###############################################################################
# Dump the parameters
###############################################################################
Write-Host ""
Write-Host "Dumping parameters:"
Write-Host "dtap: $dtap"
Write-Host "sourcePath: $sourcePath"
Write-Host "SourceVersion: $SourceVersion"
Write-Host "WhatIf: $WhatIf"

###############################################################################
# Find all parameter files for the current dtap
###############################################################################
$templateParameters = Get-ChildItem -Path $sourcePath -Include azuredeploy.*parameters.json -Recurse

Write-Host ""
Write-Host "Searching for template parameters files."
Write-Host "$($templateParameters.Count) parameter file(s) found"
Write-Host "Listing files:"

# Loop through the configs and add the right files to the list, i.e. filter on dtap setting.
# This also filters the list in deployment order.
$unsortedList = @()
$logMsg = "";
Foreach ($file in $templateParameters) {
    $params = ((Get-Content -Raw $file) | ConvertFrom-Json)
    $logMsg = "$($params.parameters.dtap.value) - $file"
    if( $params.parameters.dtap.value -eq $dtap ) {
        Write-Host "To deploy: $logMsg"
        $templateParameters = New-Object -TypeName System.Object
        $templateParameters | Add-Member -MemberType NoteProperty -Name Path -Value $file
        $templateParameters | Add-Member -MemberType NoteProperty -Name Ring -Value $params.parameters.ring.value
        $unsortedList += $templateParameters
    } else {
        Write-Host "Not to deploy: $logMsg"        
    }
}
$sortedParamFilesList = $unsortedList | Sort-Object -Property Ring


###############################################################################
# Loop through all parameter files and deploy
###############################################################################

Write-Host ""
Write-Host "Loop through all parameters files and deploy"

$jsonParamFileRegexPattern = "azuredeploy[\w\s-.]*.parameters.json$"
#$lastDirRegexPattern = "[\w\s-.]+(?=\\azuredeploy[\w\s-.]*.parameters.json$)"
$rgNamePattern = "(?<=resource-groups\\)[\w\s-.]+"
$pathNoFilenameRegexPattern = "[\w\s-.\\:]+(?=azuredeploy[\w\s-.]*.parameters.json$)"


Foreach ($paramItem in $sortedParamFilesList) {
    $path = [System.Text.RegularExpressions.Regex]::Match($paramItem.Path, $pathNoFilenameRegexPattern).Value
    Write-Host ""
    Write-Host "Deployment of $($paramItem.Path)"
    Write-Host "Path: $($path)"
    $jsonParameterFileName = [System.Text.RegularExpressions.Regex]::Match($paramItem.Path, $jsonParamFileRegexPattern).Value
    $jsonParameterFullFileName = "$($path)$($jsonParameterFileName)"
    Write-Host "Template parameters filename: $($jsonParameterFileName)"
    Write-Host "Template parameters full filename: $($jsonParameterFullFileName)"
    
    $rgName = [System.Text.RegularExpressions.Regex]::Match($paramItem.Path, $rgNamePattern).Value
    Write-Host "Resource Group Name: $($rgName)"
    $jsonTemplateFileName = $path + ($jsonParameterFileName.ToLower().Replace(".development.", ".").Replace(".dev.", ".").Replace(".test.", ".").Replace(".uat.", ".").Replace(".acc.", ".").Replace(".production.", ".").Replace(".prod.", ".").Replace(".parameters.", "."))
    Write-Host "Template file name: $($jsonTemplateFileName)"

    # Load the parameter file and set parameter(s)
    $params = ((Get-Content -Raw $paramItem.Path) | ConvertFrom-Json)
    $location = $params.parameters.location.value

    # Make sure the resource group exists
    Write-Host "Checking if Resource Group $($rgName) exists"
    $rg = Get-AzureRmResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if($rg) {
        Write-Host "Resource group $($rgName) already exists, no need to create."
    } else {
        Write-Host "Creating resource group $($rgName)"
        $rg = New-AzureRmResourceGroup -Name $rgName -Location $location -ErrorAction Stop
    }
    Write-Host $jsonTemplateFileName
    Write-Host $jsonParameterFullFileName
    $ErrorMessages = @()
    if ($WhatIf -eq $true) {
        $ErrorMessages = Format-ValidationOutput ( Test-AzureRmResourceGroupDeployment `
            -ResourceGroupName $rgName `
            -TemplateFile $jsonTemplateFileName `
            -TemplateParameterFile $jsonParameterFullFileName `
            -Verbose)
    } else {
        $deployName = "$($rgName)-$($SourceVersion)"
        New-AzureRmResourceGroupDeployment -Name $deployName `
            -ResourceGroupName $rgName `
            -Mode Incremental `
            -TemplateFile $jsonTemplateFileName `
            -TemplateParameterFile $jsonParameterFullFileName `
            -Force `
            -Verbose `
            -ErrorVariable ErrorMessages

    }

    if ($ErrorMessages)
    {
        "", ("{0} returned the following errors:" -f ("Template deployment", "Validation")[[bool]$ValidateOnly]), @($ErrorMessages) | ForEach-Object { Write-Host $_ }
        "", ("{0} returned the following errors:" -f ("Template deployment", "Validation")[[bool]$ValidateOnly]), @($ErrorMessages) | ForEach-Object { Write-Host "##vso[task.logissue type=error;] $($_)" }
    }
}

