# CloudLens installer

Install CloudLens into your own Azure subscription from Azure Cloud Shell (PowerShell).

```powershell
irm https://raw.githubusercontent.com/samy6352/cloudlens-installer/main/install-customer.ps1 -OutFile install-customer.ps1
./install-customer.ps1 -Location <region> -SubscriptionId <hosting-subscription-id> -Preview   # changes nothing
./install-customer.ps1 -Location <region> -SubscriptionId <hosting-subscription-id>
```

The script downloads release **v2026.11.24-dev4**, verifies its SHA-256 against `SHA256SUMS.txt`, then runs the guided installer.
Existing VNet: choose it when asked, enter the VNet name and pick the three subnets from the list.

Requires Owner (or Contributor + User Access Administrator) on the hosting subscription and permission to assign roles on the monitored subscriptions.
Add subscriptions later with `infra/onboard-subscriptions.ps1` from the extracted release (edit the three values at the top, then run it).