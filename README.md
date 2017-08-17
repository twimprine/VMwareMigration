# VMware Migration

## Important Notes
- Know what you are doing and test! Don't use this and mess something up. 

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
