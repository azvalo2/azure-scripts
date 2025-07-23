<#
.SYNOPSIS
    Cleans up Azure resource groups and their locks based on a user-supplied string.
.DESCRIPTION
    This script searches for Azure resource groups whose names contain a specified string, lists them, and optionally deletes them after removing any resource locks. 
    It provides options to delete all, delete all except those containing the chosen string, or skip deletion.
.NOTES
    - Requires Az PowerShell module and appropriate RBAC permissions.
#>
#Requires -Module Az.Accounts, Az.Resources

$string = Read-Host -Prompt "Enter the string to search for in resource groups"
Write-Host "----------------------------------------"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Get resource groups matching the string
$resourceGroups = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName.ToLower() -like "*$($string.ToLower())*" } | Sort-Object ResourceGroupName
$resourceGroupsCount = $resourceGroups.Count

if ($resourceGroupsCount -eq 0) {
    Write-Host "No resource groups found containing the string '$string'."
    exit
} else {
    Write-Host "$resourceGroupsCount resource groups found containing the string '$string':" -ForegroundColor Yellow
    $resourceGroups | ForEach-Object { Write-Host $_.ResourceGroupName }
    Write-Host "----------------------------------------"
    
    #Confirm deletion of resource groups
    Write-Host "Do you want to delete these resource groups?"
    Write-Host "a - yes to all"
    Write-Host "y - yes, but keep some resource groups containing specific string"
    Write-Host "n - no"
    Write-Host "----------------------------------------"
    $delete = Read-Host -Prompt "Selected: "
    $delete = $delete.Trim().ToLower()

    if ($delete -eq 'y') {
        $keepString = Read-Host -Prompt "Keep resource groups containing string"
        $resourceGroups = $resourceGroups | Where-Object { $_.ResourceGroupName -notlike "*$($keepString.ToLower())*" }
    }
    Write-Host "----------------------------------------"
    
    if ($delete -eq 'a' -or $delete -eq 'y') {
        foreach ($rg in $resourceGroups) {
            Write-Host "Processing resource group: $($rg.ResourceGroupName)" -ForegroundColor Yellow
            try {
                #Remove locks from the resource group
                $locks = Get-AzResourceLock -ResourceGroupName $rg.ResourceGroupName -ErrorAction Stop
                if ($locks.Count -eq 0) {
                    Write-Host "No locks found for resource group: $($rg.ResourceGroupName)"
                } else {
                    foreach ($lock in $locks) {
                        $error.clear()
                        if (![string]::IsNullOrWhiteSpace($lock.Name)) {
                            Write-Host "Removing lock: $($lock.Name) from resource group: $($rg.ResourceGroupName)"
                            Remove-AzResourceLock -LockName $lock.Name -ResourceGroupName $rg.ResourceGroupName -Force -ErrorAction Stop | Out-Null
                            if ($error){
                                Write-Host "Failed to remove lock: $($lock.Name). Error: $_" -ForegroundColor DarkRed
                            } else {
                                Write-Host "Removed lock: $($lock.Name)"
                            }
                            Start-Sleep -Seconds 5
                        } else {
                            Write-Host "Skipping lock removal as LockName is null or empty for resource group: $($rg.ResourceGroupName)"
                        }
                    }
                }
                #Remove the resource group
                Write-Host "Deleting resource group $($rg.ResourceGroupName)"
                Remove-AzResourceGroup -Name $rg.ResourceGroupName -Force -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Host "Deleted resource group $($rg.ResourceGroupName)" -ForegroundColor Green
            } catch {
                Write-Host "Failed to delete resource group $($rg.ResourceGroupName)." -ForegroundColor DarkRed
                Write-Host "Error: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "No resource groups were deleted."
    }
}

$stopwatch.Stop()
Write-Host "Script completed successfully in $($stopwatch.Elapsed.TotalSeconds) seconds at $(Get-Date)."
