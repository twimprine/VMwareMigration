# VMware Migration

## Important Notes
- Know what you are doing and test! Don't use this and mess something up. 
- There is obviously room for improvement so please feel free to pull and fix! I really do what honest feedback of how to do this better. 

## Environment & Usage
This script was created to provide a relatively simple and automated method to migrate from an older VMware cluster to a new shiny VMware cluster that was just installed. We are moving from IBM hardware with fibre channel storage to a VMware cluster on Dell vSAN ready nodes managed by the SDDC suite. (https://www.vmware.com/solutions/software-defined-datacenter/in-depth.html) Specificaly the Virtual Cloud Foundataion suite - We were (unwittingly) the ~40th production installation of this suite of tools and have been very pleased. 

We have a NAS device that is accessable to both clusters via 10Gb ethernet and are using that to facilitate the transfer of the virtaul machines from one cluster to the other. (IX Systems TrueNAS Z30) This is a serial workflow that migrates one system at a time. The process is as follows:
1. Retrieve all the systems that have the appropriate tag for migration. This is how I control what is getting migrated in each batch.
2. Execute a ForEach loop that will work on one system at a time.
3. Migrate the storage of the VM to the shared NAS - This is the most lengthly part of the process so I'm leaving the system up and running. 
4. Power the system off & retrieve required values (location of VMX file & network settings)
5. Unregister the system from the ORIGINAL vCenter server
6. Register the system on the NEW vCenter server
7. Update the hardware to the latest supported version of VM hardware (You need to set this in the script)
8. Remove un-needed hardware such as CDROM, Floppy, USB Devices
9. Update the network adapters to point to the correct network since they have probably changed names
10. Power the system on & Anwser questions (Yes we moved the VM)
11. Start the migration to the new storage, vSAN in my case. We do this Async since I don't need to wait and it takes a long time so we move on to the next system. 

We do log everything that happens to a file then attach that file to an email for each system. 

### How To & Such... 
Everything should be set and configured in the opening section of the script in the variables section. Look at the following code snippet and we'll walk through what they do and how to get these values from Powershell & PowerCLI. (Obviously these values have been changed to nonsense so update them accordingly)
```
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
```

`$TestRun` is used for creating and migrating test systems. It's real basic and simple, however it helps to quickly isolate and resolve problems before you try on and actual system and have a resume generating event. Just toggle this true or false. PLEASE LEVERAGE THIS FUNCTIONALITY!!!

I think the mail block is pretty self explanitory - What's your SMTP server, what address are you sending from and who is recieving it? I'm not worried about email authentication in my environemnt so I didn't include it. Could be on a TODO... 

`$OriginalVCenter` set this to either the IP address or the FQDN of your ORIGINAL vCenter server. If you use the FQDN make sure you have a solid DNS setup i.e. more than one DNS server, remember the sysems go down and reboot. 

`$OriginalVSphereAdmin` the superuser account for VSphere is what I used. You don't want to have permission problems... 
`$OriginalVSpherepassword` - If I need to explain this... This is in clear text so treat it accordingly!
`$OriginalVSphereConnection` - This is leveraged in the script and you should not need to modify it. 
`$OriginalClusterName` - Which cluster are you migrating from? This isn't as obvious in the GUI as I woul like so this value can be retrieved from PowerCLI by using the `Get-Cluster` cmdlet. 
```
PS C:\temp> get-cluster

Name                           HAEnabled  HAFailover DrsEnabled DrsAutomationLevel
                                          Level
----                           ---------  ---------- ---------- ------------------
Production                     True       1          True       FullyAutomated
View                           True       1          True       FullyAutomated

``` 
In my environment it was "Production" I was migrating from so that's what I entered here. 

`$OriginalDataCenter` - Again this is the vSphere datacenter you are migrating from, not super clear what is what from the GUI so PowerShell and PowerCLI to the rescue again. `Get-DataCenter` cmdlet will retrieve the existing values. 
```
PS C:\temp> Get-Datacenter

Name
----
XUP
```

`$MigrationTag` is the tag that the script searches for to determine what to migrate. It's currently set to "MigrationTesting" because that what I was doing, however I would recommend having multiple tags and working through them. "Development, Production, CriticalApp" etc. Update this value then run it again or in parallel. 

`$OriginalIntermediateDataStore` This is the datastore I've already presented to the ESX hosts and will be using to transfer the VM(s). In my case it was named differently between the two environments so that's why you can set it twice. PowerCLI Command:
```
PS C:\temp> Get-Datastore

Name                               FreeSpaceGB      CapacityGB
----                               -----------      ----------
XXXXX                                6,101.008      25,599.872
ssd_webroot                            198.798         199.750
IX_Z30_NAS                          86,076.513      97,091.889
XXX_Placeholder                         98.797          99.750
v7k_VMFS01_C                         1,737.745       8,191.750
VeeamBackup_XUPWVEEAM                   83.218         278.142
View_VMFS01                          1,216.786       2,047.750
REPLICATION02                          883.322       1,023.750
Repository                              68.160         149.750
VeeamBackup_XUPWVEEAM.xula....          82.999         278.142
v7k_VMFS04_C                         1,623.296       7,167.750
v7k_VMFS03                           3,541.553       5,119.750
REPLICATION ONLY                     1,636.171       3,071.750
View_VMFS02                            755.098       2,547.750
v7k_VMFS_SSD_C                         638.000       2,135.750
v7k_VMFS02_C                         2,526.046       8,191.750
v7k_VMFS03_C                         1,759.273       7,952.750
```
You can see the datastore name here is IX_Z30_NAS and that's the value to enter. On the destination side it's simply IX_Z30 so that's what I would enter there. 

TEST TEST TEST!!!!

Best of luck & feedback is always appreciated!
