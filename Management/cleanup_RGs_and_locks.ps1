<#
.SYNOPSIS
    Cleans up Azure resource groups and their locks based on a user-supplied string.
.DESCRIPTION
    This script searches for Azure resource groups whose names contain a specified string, lists them, and optionally deletes them after removing any resource locks. 
    It provides options to delete all, delete all except those containing the chosen string, or skip deletion.
.NOTES
    - Requires Az PowerShell module and appropriate RBAC permissions.
#>
#Requires -Module Az.Accounts, Az.Resources, Az.RecoveryServices

$string = Read-Host -Prompt "Enter the string to search for in resource groups"
Write-Host "----------------------------------------"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Get resource groups matching the string
$resourceGroups = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName.ToLower() -like "*$($string.ToLower())*" } | Sort-Object ResourceGroupName
$resourceGroupsCount = $resourceGroups.Count

if ($resourceGroupsCount -eq 0) {
    Write-Host "No resource groups found containing the string '$string'."
    exit
}
else {
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
        $keepString = Read-Host -Prompt "Keep resource groups containing string: "
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
                }
                else {
                    foreach ($lock in $locks) {
                        $error.clear()
                        if (![string]::IsNullOrWhiteSpace($lock.Name)) {
                            Write-Host "Removing lock: $($lock.Name) from resource group: $($rg.ResourceGroupName)"
                            Remove-AzResourceLock -LockName $lock.Name -ResourceGroupName $rg.ResourceGroupName -Force -ErrorAction Stop | Out-Null
                            if ($error) {
                                Write-Host "Failed to remove lock: $($lock.Name). Error: $_" -ForegroundColor DarkRed
                            }
                            else {
                                Write-Host "Removed lock: $($lock.Name)"
                            }
                            Start-Sleep -Seconds 10
                        }
                        else {
                            Write-Host "Skipping lock removal as LockName is null or empty for resource group: $($rg.ResourceGroupName)"
                        }
                    }
                }
            }
            catch {
                Write-Host "Failed to remove locks for resource group $($rg.ResourceGroupName)." -ForegroundColor DarkRed
                Write-Host "Error: $($_.Exception.Message)"
            }

            #Remove Backup Vault
            try {
                $VaultToDelete = $null
                $VaultToDelete = Get-AzRecoveryServicesVault -ResourceGroupName $rg.ResourceGroupName -ErrorAction Stop
                if ($VaultToDelete) {
                    Write-Host "----------------------------------------"
                    Write-Host "Removing Backup Vault: $($VaultToDelete.Name)"
                    Set-AzRecoveryServicesAsrVaultContext -Vault $VaultToDelete

                    # Attempt to disable soft delete and handle immutability
                    try {
                        Write-Host "Attempting to disable soft delete and check immutability..." -ForegroundColor Yellow
                        
                        # Try to disable soft delete using the standard PowerShell cmdlet
                        Set-AzRecoveryServicesVaultProperty -VaultId $VaultToDelete.ID -SoftDeleteFeatureState Disable
                        Write-Host "Soft delete disabled successfully" -ForegroundColor Green
                        
                        # For immutability, we'll handle it through the backup protection process
                        Write-Host "Note: If vault has immutability enabled, backup items may fail to delete completely." -ForegroundColor Yellow
                        Write-Host "This is expected behavior for immutable vaults - you may need to wait for retention periods to expire." -ForegroundColor Yellow
                        
                    }
                    catch {
                        Write-Host "Could not disable soft delete. Error: $($_.Exception.Message)" -ForegroundColor DarkRed
                        Write-Host "Proceeding with backup item cleanup anyway..." -ForegroundColor Yellow
                    }

                    # Handle soft-deleted items
                    Write-Host "Checking for soft-deleted backup items..." -ForegroundColor Yellow
                    $containerSoftDelete = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID | Where-Object { $_.DeleteState -eq "ToBeDeleted" } #fetch backup items in soft delete state
                    foreach ($softitem in $containerSoftDelete) {
                        Undo-AzRecoveryServicesBackupItemDeletion -Item $softitem -VaultId $VaultToDelete.ID -Force #undelete items in soft delete state
                    }

                    #Fetch all protected items and servers
                    $backupItemsVM = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID
                    $backupItemsSQL = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $VaultToDelete.ID
                    $backupItemsAFS = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $VaultToDelete.ID
                    $backupContainersSQL = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $VaultToDelete.ID | Where-Object { $_.ExtendedInfo.WorkloadType -eq "SQL" }
                    $protectableItemsSQL = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $VaultToDelete.ID | Where-Object { $_.IsAutoProtected -eq $true }
                    $StorageAccounts = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $VaultToDelete.ID
                    $backupServersMARS = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $VaultToDelete.ID
                    $backupServersMABS = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
                    $backupServersDPM = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType -eq "SCDPM" }

                    foreach ($item in $backupItemsVM) {
                        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure VM backup items
                    }
                    Write-Host "Disabled and deleted Azure VM backup items"

                    foreach ($item in $backupItemsSQL) {
                        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete SQL Server in Azure VM backup items
                    }
                    Write-Host "Disabled and deleted SQL Server backup items"

                    foreach ($item in $protectableItemsSQL) {
                        Disable-AzRecoveryServicesBackupAutoProtection -BackupManagementType AzureWorkload -WorkloadType MSSQL -InputItem $item -VaultId $VaultToDelete.ID #disable auto-protection for SQL
                    }
                    Write-Host "Disabled auto-protection and deleted SQL protectable items"

                    foreach ($item in $backupContainersSQL) {
                        Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $VaultToDelete.ID #unregister SQL Server in Azure VM protected server
                    }
                    Write-Host "Deleted SQL Servers in Azure VM containers"

                    foreach ($item in $backupItemsAFS) {
                        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure File Shares backup items
                    }
                    Write-Host "Disabled and deleted Azure File Share backups"

                    foreach ($item in $StorageAccounts) {
                        Unregister-AzRecoveryServicesBackupContainer -container $item -Force -VaultId $VaultToDelete.ID #unregister storage accounts
                    }
                    Write-Host "Unregistered Storage Accounts"

                    foreach ($item in $backupServersMARS) {
                        Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $VaultToDelete.ID #unregister MARS servers and delete corresponding backup items
                    }
                    Write-Host "Deleted MARS Servers"

                    foreach ($item in $backupServersMABS) {
                        Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $VaultToDelete.ID #unregister MABS servers and delete corresponding backup items
                    }
                    Write-Host "Deleted MAB Servers"

                    foreach ($item in $backupServersDPM) {
                        Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $VaultToDelete.ID #unregister DPM servers and delete corresponding backup items
                    }
                    #Deletion of ASR Items
                    $fabricObjects = Get-AzRecoveryServicesAsrFabric
                    if ($null -ne $fabricObjects) {
                        # First DisableDR all VMs.
                        foreach ($fabricObject in $fabricObjects) {
                            $containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
                            foreach ($containerObject in $containerObjects) {
                                $protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
                                # DisableDR all protected items
                                foreach ($protectedItem in $protectedItems) {
                                    Write-Host "Triggering DisableDR(Purge) for item:" $protectedItem.Name
                                    Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $protectedItem -Force
                                    Write-Host "DisableDR(Purge) completed"
                                }

                                $containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
                                # Remove all Container Mappings
                                foreach ($containerMapping in $containerMappings) {
                                    Write-Host "Triggering Remove Container Mapping: " $containerMapping.Name
                                    Remove-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainerMapping $containerMapping -Force
                                    Write-Host "Removed Container Mapping."
                                }
                            }
                            $NetworkObjects = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject
                            foreach ($networkObject in $NetworkObjects) {
                                #Get the PrimaryNetwork
                                $PrimaryNetwork = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject -FriendlyName $networkObject
                                $NetworkMappings = Get-AzRecoveryServicesAsrNetworkMapping -Network $PrimaryNetwork
                                foreach ($networkMappingObject in $NetworkMappings) {
                                    #Get the Neetwork Mappings
                                    $NetworkMapping = Get-AzRecoveryServicesAsrNetworkMapping -Name $networkMappingObject.Name -Network $PrimaryNetwork
                                    Remove-AzRecoveryServicesAsrNetworkMapping -InputObject $NetworkMapping
                                }
                            }
                            # Remove Fabric
                            Write-Host "Triggering Remove Fabric:" $fabricObject.FriendlyName
                            Remove-AzRecoveryServicesAsrFabric -InputObject $fabricObject -Force
                            Write-Host "Removed Fabric."
                        }
                    }
                    Write-Host "Warning: This script will only remove the replication configuration from Azure Site Recovery and not from the source. Please cleanup the source manually. Visit https://go.microsoft.com/fwlink/?linkid=2182781 to learn more." -ForegroundColor Yellow
                    foreach ($item in $pvtendpoints) {
                        $penamesplit = $item.Name.Split(".")
                        $pename = $penamesplit[0]
                        Remove-AzPrivateEndpointConnection -ResourceId $item.Id -Force #remove private endpoint connections
                        Remove-AzPrivateEndpoint -Name $pename -ResourceGroupName $ResourceGroup -Force #remove private endpoints
                    }
                    Write-Host "Removed Private Endpoints"

                    #Recheck ASR items in vault
                    $fabricCount = 0
                    $ASRProtectedItems = 0
                    $ASRPolicyMappings = 0
                    $fabricObjects = Get-AzRecoveryServicesAsrFabric
                    if ($null -ne $fabricObjects) {
                        foreach ($fabricObject in $fabricObjects) {
                            $containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
                            foreach ($containerObject in $containerObjects) {
                                $protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
                                foreach ($protectedItem in $protectedItems) {
                                    $ASRProtectedItems++
                                }
                                $containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
                                foreach ($containerMapping in $containerMappings) {
                                    $ASRPolicyMappings++
                                }
                            }
                            $fabricCount++
                        }
                    }

                    #Recheck presence of backup items in vault
                    $backupItemsVMFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID
                    $backupItemsSQLFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $VaultToDelete.ID
                    $backupContainersSQLFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $VaultToDelete.ID | Where-Object { $_.ExtendedInfo.WorkloadType -eq "SQL" }
                    $protectableItemsSQLFin = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $VaultToDelete.ID | Where-Object { $_.IsAutoProtected -eq $true }
                    $backupItemsSAPFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $VaultToDelete.ID
                    $backupContainersSAPFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $VaultToDelete.ID | Where-Object { $_.ExtendedInfo.WorkloadType -eq "SAPHana" }
                    $backupItemsAFSFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $VaultToDelete.ID
                    $StorageAccountsFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $VaultToDelete.ID
                    $backupServersMARSFin = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $VaultToDelete.ID
                    $backupServersMABSFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
                    $backupServersDPMFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType -eq "SCDPM" }
                    $pvtendpointsFin = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $VaultToDelete.ID

                    #Display items which are still present in the vault and might be preventing vault deletion.
                    if ($backupItemsVMFin.count -ne 0) { Write-Host $backupItemsVMFin.count "Azure VM backups are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupItemsSQLFin.count -ne 0) { Write-Host $backupItemsSQLFin.count "SQL Server Backup Items are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupContainersSQLFin.count -ne 0) { Write-Host $backupContainersSQLFin.count "SQL Server Backup Containers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($protectableItemsSQLFin.count -ne 0) { Write-Host $protectableItemsSQLFin.count "SQL Server Instances are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupItemsAFSFin.count -ne 0) { Write-Host $backupItemsAFSFin.count "Azure File Shares are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($StorageAccountsFin.count -ne 0) { Write-Host $StorageAccountsFin.count "Storage Accounts are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupServersMARSFin.count -ne 0) { Write-Host $backupServersMARSFin.count "MARS Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupServersMABSFin.count -ne 0) { Write-Host $backupServersMABSFin.count "MAB Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($backupServersDPMFin.count -ne 0) { Write-Host $backupServersDPMFin.count "DPM Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($ASRProtectedItems -ne 0) { Write-Host $ASRProtectedItems "ASR protected items are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($ASRPolicyMappings -ne 0) { Write-Host $ASRPolicyMappings "ASR policy mappings are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($fabricCount -ne 0) { Write-Host $fabricCount "ASR Fabrics are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red }
                    if ($pvtendpointsFin.count -ne 0) { Write-Host $pvtendpointsFin.count "Private endpoints are still linked to the vault. Remove the same for successful vault deletion." -ForegroundColor Red }

                    $accesstoken = Get-AzAccessToken
                    $token = $accesstoken.Token
                    $authHeader = @{
                        'Content-Type'  = 'application/json'
                        'Authorization' = 'Bearer ' + $token
                    }
                    $restUri = "https://management.azure.com//subscriptions/" + $SubscriptionId + '/resourcegroups/' + $ResourceGroup + '/providers/Microsoft.RecoveryServices/vaults/' + $VaultToDelete.Name + '?api-version=2021-06-01&operation=DeleteVaultUsingPS'
                    Invoke-RestMethod -Uri $restUri -Headers $authHeader -Method DELETE | Out-Null

                    $VaultDeleted = Get-AzRecoveryServicesVault -Name $VaultToDelete.Name -ResourceGroupName $ResourceGroup -erroraction 'silentlycontinue'
                    if ($null -eq $VaultDeleted) {
                        Write-Host "Recovery Services Vault" $VaultDeleted.Name "successfully deleted" -ForegroundColor Green
                    }
                    Write-Host "----------------------------------------"
                }
            }
            catch {
                Write-Host "Failed to remove Backup Vault for resource group $($rg.ResourceGroupName)." -ForegroundColor DarkRed
                Write-Host "Error: $($_.Exception.Message)"
            }

            #Remove the resource group
            try {
                Write-Host "Deleting resource group $($rg.ResourceGroupName)"
                Remove-AzResourceGroup -Name $rg.ResourceGroupName -Force -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Host "Deleted resource group $($rg.ResourceGroupName)" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to delete resource group $($rg.ResourceGroupName)." -ForegroundColor DarkRed
                Write-Host "Error: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Host "No resource groups were deleted."
    }
}

$stopwatch.Stop()
Write-Host "Script completed successfully in $($stopwatch.Elapsed.TotalSeconds) seconds at $(Get-Date)."
