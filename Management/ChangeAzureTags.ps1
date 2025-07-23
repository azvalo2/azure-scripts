# Author: Andrej Zvalo
# Date: 23.7.2025
# Script lists and numbers existing tags for resource (choose VM/RG/Sub/ResourceID), gives you option to modify (true/false/value) or delete them and option to exit the script
# Version: 0.1      Initial incomplete version    

function Show-Menu {
    param([string[]]$Options)
    Write-Host "Select Resource Type:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "$($i + 1). $($Options[$i])"
    }
}

function Get-Resource {
    param($ResourceType, $ResourceInput)
    Write-Host "[DEBUG] ResourceType received: $ResourceType" -ForegroundColor DarkGray
    try {
        switch ($ResourceType) {
            'VM' {
                return Get-AzVM -Name $ResourceInput -ErrorAction Stop
            }
            'RG' {
                Write-Host "[DEBUG] Fetching Resource Group: $ResourceInput" -ForegroundColor DarkGray
                return Get-AzResourceGroup -Name $ResourceInput -ErrorAction Stop
            }
            'Sub' {
                try {
                    return Get-AzSubscription -SubscriptionId $ResourceInput -ErrorAction Stop
                } catch {
                    $sub = Get-AzSubscription | Where-Object { $_.Name -eq $ResourceInput }
                    if (-not $sub) { throw "Subscription '$ResourceInput' not found by name or ID." }
                    return $sub
                }
            }
            'ResourceId' {
                return Get-AzResource -ResourceId $ResourceInput -ErrorAction Stop
            }
            default {
                Write-Host "[DEBUG] Unknown ResourceType: $ResourceType" -ForegroundColor Red
                throw "Invalid resource type: $ResourceType"
            }
        }
    } catch {
        throw $_
    }
}

function Update-Tags {
    param($ResourceType, $ResourceObj, $Tags, $Operation)
    try {
        switch ($ResourceType) {
            'VM' {
                Set-AzResource -ResourceId $ResourceObj.Id -Tag $Tags -Force -Confirm:$false -ErrorAction Stop | Out-Null
            }
            'RG' {
                Set-AzResourceGroup -Name $ResourceObj.ResourceGroupName -Tag $Tags -ErrorAction Stop | Out-Null
            }
            'Sub' {
                $subResourceId = "/subscriptions/$($ResourceObj.Id)"
                if ($Operation -eq 'Delete') {
                    Update-AzTag -ResourceId $subResourceId -Tag $Tags -Operation Delete -ErrorAction Stop | Out-Null
                } else {
                    Update-AzTag -ResourceId $subResourceId -Tag $Tags -Operation Merge -ErrorAction Stop | Out-Null
                }
            }
            'ResourceId' {
                Set-AzResource -ResourceId $ResourceObj.ResourceId -Tag $Tags -Force -Confirm:$false -ErrorAction Stop | Out-Null
            }
        }
        Write-Host "Tags updated in Azure." -ForegroundColor Cyan
    } catch {
        Write-Host "Failed to update tags: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-TagsMenu {
    param($Tags)
    Write-Host "Existing tags:" -ForegroundColor Yellow
    $tagList = $Tags.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Key = $_.Key; Value = $_.Value } }
    for ($i = 0; $i -lt $tagList.Count; $i++) {
        Write-Host "$($i + 1). $($tagList[$i].Key): $($tagList[$i].Value)" -ForegroundColor Green
    }
    return $tagList
}

# Ensure Az module is imported and user is logged in
if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Host "Az module not found. Please install Az PowerShell module." -ForegroundColor Red
    exit 1
}
if (-not (Get-AzContext)) {
    Write-Host "Not logged in. Please authenticate to Azure." -ForegroundColor Yellow
    Connect-AzAccount
}

# Resource type selection and input loop
$resourceType = $null
$resourceInput = $null
$resourceObj = $null
while ($true) {
    $options = @("Virtual Machine (VM)", "Resource Group (RG)", "Subscription", "Resource ID", "Exit")
    Show-Menu -Options $options
    $resourceTypeMap = @{ 1 = 'VM'; 2 = 'RG'; 3 = 'Sub'; 4 = 'ResourceId'; 5 = 'Exit' }
    do {
        Write-Host "Enter the number corresponding to your choice: " -ForegroundColor Yellow -NoNewline
        $selection = Read-Host
        $isValid = $selection -as [int] -and $selection -ge 1 -and $selection -le $options.Count
        if (-not $isValid) {
            Write-Host "Invalid selection. Please enter a number between 1 and $($options.Count)." -ForegroundColor Red
        }
    } while (-not $isValid)
    $resourceType = $resourceTypeMap[[int]$selection]
    if ($resourceType -eq 'Exit') { Write-Host "Exiting."; exit }

    $resourceInput = $null
    $resourceObj = $null
    $returnToMainMenu = $false
    while (-not $returnToMainMenu) {
        if ($resourceType -eq 'VM') {
            Write-Host "Enter the VM name: " -ForegroundColor Yellow -NoNewline
            $vmName = Read-Host
            if ($vmName -eq 'back') { break }
            $vms = Get-AzVM | Where-Object { $_.Name.ToLower() -eq $vmName.ToLower() }
            if (-not $vms) {
                Write-Host "No VM found with the name '$vmName'. Please try again." -ForegroundColor Red
                $allVmNames = Get-AzVM | Select-Object -ExpandProperty Name | Sort-Object -Unique
                if ($allVmNames) {
                    Write-Host "Available VM names in this subscription/context:" -ForegroundColor Cyan
                    $allVmNames | ForEach-Object { Write-Host $_ }
                }
                continue
            } elseif ($vms.Count -eq 1) {
                $resourceObj = $vms
                $vmRg = $resourceObj.ResourceGroupName
                $resourceInput = $resourceObj.Id
            } else {
                Write-Host "Multiple VMs found with the name '$vmName'."
                for ($i = 0; $i -lt $vms.Count; $i++) {
                    Write-Host "$($i + 1). Resource Group: $($vms[$i].ResourceGroupName) | Location: $($vms[$i].Location)"
                }
                do {
                    Write-Host "Enter the number of the VM (resource group) you want to select: " -ForegroundColor Yellow -NoNewline
                    $vmSelection = Read-Host
                    $isValidVm = $vmSelection -as [int] -and $vmSelection -ge 1 -and $vmSelection -le $vms.Count
                    if (-not $isValidVm) {
                        Write-Host "Invalid selection. Please enter a valid number." -ForegroundColor Red
                    }
                } while (-not $isValidVm)
                $resourceObj = $vms[$vmSelection - 1]
                $vmRg = $resourceObj.ResourceGroupName
                $resourceInput = $resourceObj.Id
            }
        } else {
            Write-Host "Enter the resource name or ID (or type 'back' to return): " -ForegroundColor Yellow -NoNewline
            $resourceInput = Read-Host
            if ($resourceInput -eq 'back') { break }
            try {
                $resourceObj = Get-Resource -ResourceType $resourceType -ResourceInput $resourceInput
            } catch {
                Write-Host "Failed to fetch the resource: $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }
        # Tag management loop
        :TagMenu while ($true) {
            $tags = $resourceObj.Tags
            if (-not $tags -or $tags.Count -eq 0) {
                Write-Host "No tags found for the specified resource." -ForegroundColor Yellow
                $tags = @{
                }
            }
            $tagList = Show-TagsMenu -Tags $tags
            Write-Host "What would you like to do with the tags?" -ForegroundColor Yellow
            Write-Host "1. Modify a tag"
            Write-Host "2. Toggle a tag's value between true/false"
            Write-Host "3. Delete a tag"
            Write-Host "4. Add a new tag"
            Write-Host "5. Back"
            $tagSelection = Read-Host -Prompt "Choose the operation you want to do"
            switch ($tagSelection) {
                1 {
                    $tagNumber = Read-Host -Prompt "Enter the number of the tag you want to modify"
                    if ($tagNumber -as [int] -and $tagNumber -ge 1 -and $tagNumber -le $tagList.Count) {
                        $selectedTag = $tagList[$tagNumber - 1]
                        $tagKey = $selectedTag.Key
                        $tagValue = Read-Host -Prompt "Enter the new value for the tag '$tagKey'"
                        $tags[$tagKey] = $tagValue
                        Update-Tags -ResourceType $resourceType -ResourceObj $resourceObj -Tags $tags -Operation 'Merge'
                    } else {
                        Write-Host "Invalid selection. Please enter a valid tag number." -ForegroundColor Red
                    }
                }
                2 {
                    $tagNumber = Read-Host -Prompt "Enter the number of the tag you want to toggle"
                    if ($tagNumber -as [int] -and $tagNumber -ge 1 -and $tagNumber -le $tagList.Count) {
                        $selectedTag = $tagList[$tagNumber - 1]
                        $tagKey = $selectedTag.Key
                        $currentValue = $selectedTag.Value
                        if ($currentValue -match "^(?i)true$") {
                            $tags[$tagKey] = "false"
                        } elseif ($currentValue -match "^(?i)false$") {
                            $tags[$tagKey] = "true"
                        } else {
                            Write-Host "Tag '$tagKey' does not have a true/false value. No changes made." -ForegroundColor Yellow
                            continue
                        }
                        Update-Tags -ResourceType $resourceType -ResourceObj $resourceObj -Tags $tags -Operation 'Merge'
                    } else {
                        Write-Host "Invalid selection. Please enter a valid tag number." -ForegroundColor Red
                    }
                }
                3 {
                    $tagNumber = Read-Host -Prompt "Enter the number of the tag you want to delete"
                    if ($tagNumber -as [int] -and $tagNumber -ge 1 -and $tagNumber -le $tagList.Count) {
                        $selectedTag = $tagList[$tagNumber - 1]
                        $tagKey = $selectedTag.Key
                        if ($resourceType -eq 'Sub') {
                            $delTags = @{$tagKey = $null}
                            Update-Tags -ResourceType $resourceType -ResourceObj $resourceObj -Tags $delTags -Operation 'Delete'
                        } else {
                            $tags.Remove($tagKey)
                            Update-Tags -ResourceType $resourceType -ResourceObj $resourceObj -Tags $tags -Operation 'Merge'
                        }
                    } else {
                        Write-Host "Invalid selection. Please enter a valid tag number." -ForegroundColor Red
                    }
                }
                4 {
                    $tagKey = Read-Host -Prompt "Enter the new tag key"
                    $tagValue = Read-Host -Prompt "Enter the value for the new tag"
                    if (-not $tags.ContainsKey($tagKey)) {
                        $tags[$tagKey] = $tagValue
                        Update-Tags -ResourceType $resourceType -ResourceObj $resourceObj -Tags $tags -Operation 'Merge'
                    } else {
                        Write-Host "Tag '$tagKey' already exists. Please choose a different key." -ForegroundColor Red
                    }
                }
                5 {
                    Write-Host "Returning to previous menu." -ForegroundColor Yellow
                    $resourceInput = $null
                    $resourceObj = $null
                    $returnToMainMenu = $true
                    break TagMenu
                }
                default {
                    Write-Host "Invalid selection. Please enter a valid option." -ForegroundColor Red
                }
            }
            # Refresh resource object after update
            try {
                if ($resourceType -eq 'VM') {
                    $resourceObj = Get-AzVM -Name $vmName -ResourceGroupName $vmRg -ErrorAction Stop
                } elseif ($resourceType -eq 'Sub') {
                    $resourceObj = Get-AzSubscription -SubscriptionId $resourceObj.Id -ErrorAction Stop
                    $tags = $resourceObj.Tags  # Always refresh tags for Sub
                } else {
                    $resourceObj = Get-Resource -ResourceType $resourceType -ResourceInput $resourceInput
                }
            } catch {
                Write-Host "Failed to refresh resource: $($_.Exception.Message)" -ForegroundColor Red
                $returnToMainMenu = $true
                break
            }
        }
        if ($returnToMainMenu) { break }
    }
}
