<#
Author:     Thomas Wimprine
Date:       August 14, 2017
Purpose:    This script was created to migrate guest systems to a new VMware cluster. 

License: 
# The MIT License (MIT)
#
# Copyright:: 2017, Thomas Wimprine
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

#>

<#
#################################################
########## NOTES ################################
#################################################
- If possible make sure the VM names do not have any special characters
#>


#################################################
#####   Variables ###############################
#################################################

$TestRun = $true
#$TestRun = $false

$MailServer = "mail.domain.com"
$EmailTo = "you@domain.com"
$EmailFrom = "VMMigration@domain.com"

$OriginalVCenter = "127.0.0.1"
$OriginalVSphereAdmin = "administrator@vsphere.local"
$OriginalVSpherePassword = "SuperSecretPassword"   
$OriginalVSphereConnection = $null
$OriginalClusterName = "Zeke"
$OriginalDataCenter = "SecretLair"
$MigrationTag = "MigrationTesting"
$OriginalIntermediateDataStore = "SharedNAS"

$DestinationVCenter = "127.0.0.2"
$DestinationVSphereAdmin = "administrator@vsphere.local"
$DestinationVSpherePassword = "NewSuperSecretPassword"
$DestinationVSphereConnection = $null
$DestinationClusterName = "Vega"
$DestinationDatacenter = "NewAndImprovedSecretLair"
$DestinationIntermediateDataStore = "SharedNAS_NewName"
$DestinationTargetDataStore = "vsanDatastore"

$MaxSupportedHWVersion = 11
$LogFileRoot = "C:\temp\Migration"
$global:LogFile = $LogFileRoot + "_Conection.log"

#################################################
###### Network PortGroup HASHES #################
#################################################

$NetworkPortGroups = @{
    "VLAN_100"	=	"vRack-DPortGroup-External-VLAN_100";
    "VLAN_200"	=	"vRack-DPortGroup-External-VLAN_200";
    "VLAN_300"	=	"vRack-DPortGroup-External-VLAN_300";
    "VLAN_400"	=	"vRack-DPortGroup-External-VLAN_400";
    "VLAN_500"	=	"vRack-DPortGroup-External-VLAN_500";
}

#################################################
#####   End Variables ###########################
#################################################

function InitLogFile {
    param($Logfile)
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
    }
    $Time = Get-Date -UFormat %T
    $OutString = $Time + " - Initializing Log File"
    $OutString | Out-File $LogFile
}

function Log {
    param($LogData)
    if ($global:Logfile -eq $null) {
        Write-Error "Cannont write logfile : $global:Logfile"
        break
    }
    $Time = Get-Date -UFormat %T 
    $OutString = $Time + " - " + $LogData
    $OutString | Out-File -Append $global:Logfile
}
Function GetOriginalVCenterPassword {
    if ($OriginalVSpherePassword -eq $null) {
        $OriginalVSpherePassword = Read-Host -Prompt "Enter the password for $OriginalVSphereAdmin on the Original VCenter"
    }
}
Function GetDestinationVCenterPassword {
    if ($DestinationVSpherePassword -eq $null) {
        $DestinationVSpherePassword = Read-Host -Prompt "Enter the password for $DestinationVSphereAdmin for the Destination VCenter"
    }
}

Function ConnectOriginalVCenter {
    GetOriginalVCenterPassword
    try {
        Connect-VIServer -Server $OriginalVCenter -User $OriginalVSphereAdmin -Password $OriginalVSpherePassword
        Log("Established Connection to $OriginalVCenter")
    }
    catch {
        Log("Didn't establish connection with $OriginalVCenter : $_")
    }
    return $global:DefaultVIServers | Where-Object {$_.Name -eq $OriginalVCenter}
}

Function ConnectDestinationVCenter {
    GetDestinationVCenterPassword
    Try {
        Connect-VIServer -Server $DestinationVCenter -User $DestinationVSphereAdmin -Password $DestinationVSpherePassword
        Log("Established Connection to $DestinationVCenter")
    }
    catch {
        Log("Didn't establish connection with $DestinationVCenter : $_")
    }
    return $global:DefaultVIServers | Where-Object {$_.Name -eq $DestinationVCenter}
}

function SendEmail {
    param($Computer,
        $Data)

    $Date = Get-Date

    if ($Data -eq $null) {
        $Subject = "Starting Migration of $Computer at " + $Date
        $Body = "$Date"
        Log("Composed Start Email")
        Send-MailMessage -SmtpServer $MailServer -From $EmailFrom -To $EmailTo -Subject $Subject -Body $Body 
    }
    else {
        $Subject = "Migration Log of $Computer at " + $Date
        $Body = "See attachment for log information"
        $Attachment = $LogFile
        Send-MailMessage -SmtpServer $MailServer -From $EmailFrom -To $EmailTo -Subject $Subject -Body $Body -Attachments $Attachment 
    }

}

function Get-VMHWVersion {
    # I needed this as an [int] so I created a function for it. 
    param($VM)
    $Version = Get-VM $VM | Select-Object Version -First 1
    $HWVersion = $Version -replace '\D+(\d+)\D+', '$1'
    Log("VM is version $HWVersion")
    return $HWVersion
}
function MigrateStorage {
    param(
        $VM,
        $DataStoreName,
        $VCenter,
        $DataCenterName,
        $Async)
    
    # I have $Async here because I need to wait for the machine to be migrated to the shared storage,
    # however on the second migration from the shared storage to new primary (vSAN) I can move on 
    # to processing another VM for migration. 
    $VMName = $VM.Name
    $DataCenter = Get-Datacenter $DataCenterName
    $DataStore = Get-Datastore -Name $DataStoreName -Server $VCenter -Location $Datacenter    
    Log("Starting Storage Migration to $DataStoreName")
    if ($Async) {
        try {
            Get-VM $VM | Move-VM -Datastore $DataStore -Confirm:$false -RunAsync
            Log("Completed storage migration of $VMName to $DataStore")
        }
        catch {
            Log("Storage Migration Failed: $_")
        }
    }
    else {
        try {
            Get-VM $VM | Move-VM -Datastore $DataStore -Confirm:$false -Server $VCenter
            Log("Completed storage migration of $VMName to $DataStore")
        }
        catch {
            Log("Storage Migration Failed: $_")
        }
    }

}

function PowerSystemOff {
    param($VM)
    $SystemName = $VM.Name
    if ($VM.PowerState -eq "PoweredOn") {
        Log("Starting PowerOff of $SystemName")
        if ($VM.Guest.ToolsVersion -ne "") {
            try {
                Log("VMTools installed trying OS Power Off")
                $VM | Shutdown-VMGuest -Confirm:$false
                Start-Sleep -Seconds 30
                $Counter = 0
                while ($VM.PowerState -eq "PoweredOn") {
                    Start-Sleep -Seconds 60
                    $VM = Get-VM $VM
                    $Counter++
                    $Time = Get-Date -UFormat %T
                    Log("Waiting for shutdown - $Time")
                    if ($Counter -gt 20) {
                        $Time = Get-Date -UFormat %T
                        Log("Waited 20 min for shudown - forcing shutdown")
                        Stop-VM -VM $VM -Confirm:$false
                    }

                }
                Log("Shutdown of $SystemName Succeeded")
            }
            Catch {
                Log("Failed to shutdown VM $SystemName")
            }
        }
        else {
            Log("VMTools is not installed Hard poweroff required... :( ")
            Stop-VM -VM $VM -Confirm:$false
            while ($VM.PowerState -eq "PoweredOn") {
                Start-Sleep -Seconds 10
                $VM = Get-VM $VM
            }
            Log("$SystemName has been powered off")
        }
    }
    else {
        Log("System is already powered off")
    }
}

function RemoveVirtualHardware {
    # I'm removing the virtual hardware that may be attached to the system. Also
    # I am utilizing a foreach for each type of hardware. It's possible to have 
    # more than one device attached to a system so we need to ensure they are all
    # removed. 

    # Considering breaking this into seperate functions... :/

    param($VM)
    $SystemName = $VM.Name
    # We need to ensure the system is off before proceeding
    $VM = Get-VM $VM
    if ($VM.PowerState -eq "Poweredoff") {
        #Remove CDRom
        if ($HW = Get-VM $VM | Get-CDDrive) {
            $Count = $HW.Count
            Log("Removing CDROM(s) on $SystemName")
            Log("System has $Count CDROM Drives")
            foreach ($CDROM in $HW) {
                try {
                    Remove-CDDrive -CD $CDROM -Confirm:$false
                    Log("Removed CDROM from $SystemName")
                }
                catch {
                    Log("Was unable to remove CDROM from $SystemName : $_")
                }
            }
        }
        else {
            Log("No CDROM Device installed on $SystemName")
        }

        #Remove Floppy Drive
        if ($HW = Get-VM $VM | Get-FloppyDrive) {
            $Count = $HW.Count
            Log("Removing Floppy Drive from $SystemName")
            Log("System has $Count Floppy Drives")
            foreach ($Floppy in $HW) {
                try {
                    Remove-FloppyDrive -Floppy $Floppy -Confirm:$false
                    Log("Removed Floppy from $SystemName")
                }
                catch {
                    Log("Floppy drive removal failed for system $SystemName : $_")
                }
            }
        }
        else {
            Log("No Floppy device installed on $SystemName")
        }

        #Remove USB Devices
        if ($HW = Get-VM $VM | Get-UsbDevice) {
            $Count = $HW.Count
            Log("Removing USB Devices")
            Log("System has $Count USB Devices attached")
            foreach ($USB in $HW) {
                try {
                    Remove-UsbDevice -UsbDevice $USB -Confirm:$false
                }
                catch {
                    Log("USB Device removal failed for system $SystemName : $_")
                }
            }
        }
        else {
            Log("No USB Devices found on $SystmName")
        }
    }
    else {
        PowerSystemOff($VM)
        RemoveVirtualHardware($VM)
    }
}

function ChangeVirtualHardwareVersion {
    param($VM)

    # Link to supported VM Hardware versions
    # https://kb.vmware.com/selfservice/microsites/search.do?language=en_US&cmd=displayKC&externalId=1003746

    # Check the power state
    $VM = Get-VM $VM
    if ($VM.PowerState -eq "PoweredOff") {
        $Version = $VM.Version
        $SystemName = $VM.Name
        Log("$SystemName is currently at version : $Version")
        [string]$MaxVersion = "v" + $MaxSupportedHWVersion
        if ($Version -ne $MaxVersion) {
            Log("Version is not where it needs to be - Updating... ")
            try {
                Set-VM -VM $VM -Version:$MaxVersion -Confirm:$false
                Start-Sleep -Seconds 1
                if (Get-VMQuestion -VM $VM ) {
                    Log("VM has a question regarding hardware and VMTools - Resolving")
                    Get-VMQuestion -VM $VM | Set-VMQuestion -Option "button.ok" -Confirm:$false
                }
                Log("Updated the HW version to $MaxVersion")
            }
            catch {
                Log("Was unable to update the virtual hw version : $_")
            }
        }
    }
    else {
        Log("System was not powered off - Powering off now")
        PowerSystemOff($VM)
        ChangeVirtualHardwareVersion($VM)
    }
}

function UnregisterVirtualMachine {
    param($VM)
    try {
        Log("Unregistering system from $OriginalVCenter")
        Get-VM $VM | Remove-VM -DeletePermanently:$false -Confirm:$false
    }
    catch {
        Log("Was unable to unregister $VM.Name from $OriginalVCenter : $_")
    }
}

function RegisterVirtualMachine {
    param($VM,
        $VMXFile)

    $Name = $VM.Name

    # Get a random ESXhost to place the newly registered systems on 
    # good idea I got from @pcradduck
    $ESXHost = Get-Cluster -Name $DestinationClusterName -Server $DestinationVCenter | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected"} | Get-Random

    try {
        #Update old path with new
        Log("Registering $Name on $DestinationVCenter")
        $New_VMXLocation = $VMXFile.replace($OriginalIntermediateDataStore, $DestinationIntermediateDataStore)
        New-VM -VMHost $ESXHost -Name $Name -VMFilePath $New_VMXLocation
        Log("Completed registration of $Name on new VCenter")
    }
    catch {
        Log("Failed registration of $Name")
    }

}

function UpdateNetworkAdapters {
    param($VM,
        $NetworkAdapters,
        $VCenterServer)

    Log("Setting new network adapters")
    foreach ($Adapter in $NetworkAdapters) {
        $VMName = $VM.Name
        $NetworkName = $Adapter.NetworkName
        $AdapterName = $Adapter.Name
        Log("Updating network settings for $VMName")
        Log("Changing $AdapterName to $NetworkName)")
        $NewPortGroup = Get-VDPortGroup -Name $NetworkPortGroups.Item($NetworkName) -Server $VCenterServer
        try {
            $Adapter = Get-VM $VMName -Server $VCenterServer | Get-NetworkAdapter -Name $AdapterName -Server $VCenterServer
            $Adapter | Set-NetworkAdapter -Portgroup $NewPortGroup -Confirm:$false -Server $VCenterServer 
            Log("Set network adapter to $NewPortGroup : $_")
        }
        catch {
            Log("Failed to set network adapter to $NewPortGroup : $_")
        }
    }
}

function CreateTestVM {
    # Creates basic VM for testing and migration
    # Does NOT handle clean-up - you need to do that on your own... :)
    $HDSizeGB = 10     # I'm decimally challendged so this just makes is easier and I don't accidently create a 1TB drive... ¯\_(ツ)_/¯
    $NumberOfTest = 10 
    
    $Tag = Get-Tag $MigrationTag -Server $OriginalVCenter
    $HDSize = 1024 * $HDSizeGB
    
    for ($i = 0; $i -le $NumberOfTest - 1; $i++) {
        $TestVMName = "TestVM" + $i
        $ESXHost = Get-Cluster -Name $OriginalClusterName -Server $OriginalVCenter | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected"} | Get-Random
        New-VM -Name $TestVMName -VMHost $ESXHost -DiskMB $HDSize -MemoryMB 4096 -Server $OriginalVCenter -NetworkName Access_PG -CD -Floppy -Version:v4
        Get-VM $TestVMName | New-TagAssignment -Tag $Tag
        Start-VM -VM $TestVMName
        Start-Sleep -Seconds 1
    }
}

#####################################
# Start Processing
#####################################

#Establish VCenter Connections
$OriginalVSphereConnection = ConnectOriginalVCenter
$DestinationVSphereConnection = ConnectDestinationVCenter

# Create Testing VM(s)
# Enable / Disable by setting $TestRun to true/false in the variables section
if ($TestRun) {
    CreateTestVM
}

$Systems = Get-VM -Server $OriginalVSphereConnection -Tag $MigrationTag

foreach ($System in $Systems) {
    $SystemName = $System.Name

    <# 
    Ok this is a litte log file naming hackery - There was a timing problem with the system moving on to the next migration
    before the last storage migration was logged and closed, thus overwritting the log file. Unfortunatly I needed
    to change it to individual log files per system. Honestly, it's better anyway just wasn't my original solution. 
    #>
    $global:LogFile = $LogFileRoot + "_$SystemName.txt"
    InitLogFile $LogFile
    
    Log("Starting Migration of $SystemName")
    SendEmail -Computer $SystemName -Data $null 
    [int]$VMHWVersion = Get-VMHWVersion -VM $System
    if ($VMHWVersion -lt $MaxSupportedHWVersion + 1) {
        # Get the existing state of the system - we will need it when we re-register it. 
        $PowerState = $System.PowerState
        $NetworkAdapters = Get-NetworkAdapter -VM $System -Server $OriginalVCenter
        
        # Start Machine Migrations
        Log("Starting Migrations")
        MigrateStorage -VM $System -DataStoreName $OriginalIntermediateDataStore -VCenter $OriginalVCenter -DataCenterName $OriginalDataCenter -Async $false
        Log("Powering System Off")
        PowerSystemOff -VM $System

        #Update the object information
        $System = Get-VM $System -Server $OriginalVCenter
        $VMXPath = $System.ExtensionData.Config.Files.VmPathName
        
        Log("Removing system from original VCenter")
        UnregisterVirtualMachine -VM $System
        Log("Registering VM on new VCenter")
        RegisterVirtualMachine -VM $System -VMXFile $VMXPath

        #Update the object Info again
        $System = Get-VM $System -Server $DestinationVCenter

        Log("Removing Virtual Hardware")
        RemoveVirtualHardware -VM $System
        Log("Updating Virtual Hardware Version")
        ChangeVirtualHardwareVersion -VM $System 

        Log("Updating Network Adapters")
        UpdateNetworkAdapters -VM $System -NetworkAdapters $NetworkAdapters -VCenterServer $DestinationVCenter

        #Return the system to the original powerstate
        if ($PowerState -eq "PoweredOn") {
            Start-VM $System
            Start-Sleep -Seconds 10
            # Anwser question
            Get-VMQuestion | Set-VMQuestion -Option 'button.uuid.movedTheVM' -Confirm:$false
        }

        # Storage vMotion to the vSAN 
        Log("Starting Last migration to vSAN")
        MigrateStorage -VM $System -DataStoreName $DestinationTargetDataStore -VCenter $DestinationVCenter -DataCenterName $DestinationDatacenter -Async $true

        Log("Finished Migration for $System.Name")
    }
    else {
        Log("System is at HW Version $VMHWVersion and it currently exceeds what the envronment supports")
    }
    SendEmail $SystemName $true 
}