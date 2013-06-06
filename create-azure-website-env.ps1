﻿# How to run the script
# create-azure-env.ps1 -Name yourwebsitename -SqlDatabasePassw0rd P@ssw0rd

# Define input parameters
Param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[a-z0-9]*$")]
    [String]$Name,                             # required    needs to be alphanumeric
    
    [String]$Location = "West US",             # optional    default to "West US", needs to be a location which all the services created here are available
    
    [String]$SqlDatabaseUserName = "dbuser",   # optional    default to "dbuser"
    
    [Parameter(Mandatory = $true)]
    [String]$SqlDatabasePassword,              # required    you can set the value here and make the parameter optional
    
                                               # optional    start IP address of the range you want to whitelist in SQL Azure firewall
    [String]$StartIPAddress,                   #             will try to detect if not specified

                                               # optional    end IP address of the range you want to whitelist in SQL Azure firewall
    [String]$EndIPAddress                      #             will try to detect if not specified
    )

# Begin - Helper functions --------------------------------------------------------------------------------------------------------------------------

# Generate connection string of a given SQL Azure database
Function Get-SQLAzureDatabaseConnectionString
{
    Param(
        [String]$DatabaseServerName,
        [String]$DatabaseName,
        [String]$UserName,
        [String]$Password
    )

    Return "Server=tcp:{0}.database.windows.net,1433;Database={1};User ID={2}@{0};Password={3};Trusted_Connection=False;Encrypt=True;Connection Timeout=30;" -f
        $DatabaseServerName, $DatabaseName, $UserName, $Password
}

# Generate environment xml file, which will be used by the deploy script later.
Function Generate-EnvironmentXml
{
    Param(
        [String]$EnvironmentName,
        [String]$WebsiteName,
        [String]$StorageAccountName,
        [String]$StorageAccountAccessKey,
        [String]$DatabaseServerName,
        [String]$DatabaseName,
        [String]$DatabaseUserName,
        [String]$DatabasePassword
    )

    [String]$template = Get-Content ("{0}\website-environment.template" -f $scriptPath)

    ($template -f $EnvironmentName, $WebsiteName, $StorageAccountName, $StorageAccountAccessKey, $DatabaseServerName, $DatabaseName, $DatabaseUserName, $DatabasePassword) `
        | Out-File -Encoding utf8 ("{0}\website-environment.xml" -f $scriptPath)
}

# Generate the publish xml which will be used by MSBuild to deploy the project to website.
Function Generate-PublishXml
{
    Param(
        [Parameter(Mandatory = $true)]
        [String]$WebsiteName
    )
    
    # Get the current subscription you are working on
    $s = Get-AzureSubscription -Current
    # Get the certificate of the current subscription from your local cert store
    $cert = Get-ChildItem ("Cert:\CurrentUser\My\{0}" -f $s.Certificate.Thumbprint)
    $website = Get-AzureWebsite -Name $WebsiteName
    # Compose the REST API URI from which you will get the publish settings info
    $uri = "https://management.core.windows.net:8443/{0}/services/WebSpaces/{1}/sites/{2}/publishxml" -f `
        $s.SubscriptionId, $website.WebSpace, $Website.Name

    # Get the publish settings info from the REST API
    $publishSettings = Invoke-RestMethod -Uri $uri -Certificate $cert -Headers @{"x-ms-version" = "2013-06-01"}

    # Save the publish settings info into a .publishsettings file
    # and read the content as xml
    $publishSettings.InnerXml > ("{0}\{1}.publishsettings" -f $scriptPath, $WebsiteName)
    [Xml]$xml = Get-Content ("{0}\{1}.publishsettings" -f $scriptPath, $WebsiteName)

    # Get the publish xml template and generate the .pubxml file
    [String]$template = Get-Content ("{0}\pubxml.template" -f $scriptPath)
    ($template -f $website.HostNames[0], $xml.publishData.publishProfile.publishUrl.Get(0), $WebsiteName) `
        | Out-File -Encoding utf8 ("{0}\{1}.pubxml" -f $scriptPath, $WebsiteName)
}

# End - Helper funtions -----------------------------------------------------------------------------------------------------------------------------


# Begin - Actual script -----------------------------------------------------------------------------------------------------------------------------

# Set the output level to verbose and make the script stop on error
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# Mark the start time of the script execution
$startTime = Get-Date

Write-Verbose ("[Start] creating Windows Azure website environment {0}" -f $Name)

# Get the directory of the current script
$scriptPath = Split-Path -parent $PSCommandPath

# Define the names of website, storage account, SQL Azure database and SQL Azure database server firewall rule
$Name = $Name.ToLower()
$websiteName = $Name
$storageAccountName = "{0}storage" -f $Name
$sqlDatabaseName = "appdb"
$sqlDatabaseServerFirewallRuleName = "{0}rule" -f $Name

# Create a new website
Write-Verbose ("[Start] creating website {0} in location {1}" -f $websiteName, $Location)
$website = New-AzureWebsite -Name $websiteName -Location $Location -Verbose
Write-Verbose ("[Finish] creating website {0} in location {1}" -f $websiteName, $Location)

# Create a new storage account
$storageAccount = & "$scriptPath\create-azure-storage.ps1" `
    -Name $storageAccountName `
    -Location $Location

# Create a SQL Azure database server and a database
$sql = & "$scriptPath\create-azure-sql.ps1" `
    -DatabaseName $sqlDatabaseName `
    -UserName $SqlDatabaseUserName `
    -Password $SqlDatabasePassword `
    -FirewallRuleName $sqlDatabaseServerFirewallRuleName `
    -Location $Location `
    -StartIPAddress $StartIPAddress `
    -EndIPAddress $EndIPAddress

$sqlDatabaseServerName = $sql.Server.ServerName

# Get the connection string of the SQL Azure database
$appDBConnectionString = Get-SQLAzureDatabaseConnectionString -DatabaseServerName $sqlDatabaseServerName `
    -DatabaseName $sqlDatabaseName -UserName $SqlDatabaseUserName -Password $SqlDatabasePassword
$memberDBConnectionString = Get-SQLAzureDatabaseConnectionString -DatabaseServerName $sqlDatabaseServerName `
    -DatabaseName "memberdb" -UserName $SqlDatabaseUserName -Password $SqlDatabasePassword
# Get the access key of the storage account
$storageAccountAccessKey = Get-AzureStorageKey -StorageAccountName $storageAccountName -Verbose

# Add the connection string and storage account name/key to the website
Write-Verbose ("[Start] Adding settings to website {0}" -f $websiteName)
Write-Verbose "Connection Strings"
Write-Verbose ("{0} = {1}" -f $sqlDatabaseName, $appDBConnectionString)
Write-Verbose ("{0} = {1}" -f "DefaultConnection", $memberDBConnectionString)
Write-Verbose "App Settings"
Write-Verbose ("{0} = {1}" -f "StorageAccountName", $storageAccountName)
Write-Verbose ("{0} = {1}" -f "StorageAccountAccessKey", $storageAccountAccessKey.Primary)

# Configure app settings for storage account and New Relic
$appSettings = @{ `
    "StorageAccountName" = $storageAccountName; `
    "StorageAccountAccessKey" = $storageAccountAccessKey.Primary; `
    "COR_ENABLE_PROFILING" = "1"; `
    "COR_PROFILER" = "{71DA0A04-7777-4EC6-9643-7D28B46A8A41}"; `
    "COR_PROFILER_PATH" = "C:\Home\site\wwwroot\newrelic\NewRelic.Profiler.dll"; `
    "NEWRELIC_HOME" = "C:\Home\site\wwwroot\newrelic" `
}

# Configure connection strings for appdb and ASP.NET member db
$connectionStrings = ( `
    @{Name = $sqlDatabaseName; Type = "SQLAzure"; ConnectionString = $appDBConnectionString}, `
    @{Name = "DefaultConnection"; Type = "SQLAzure"; ConnectionString = $memberDBConnectionString}
)

Set-AzureWebsite -Name $websiteName -AppSettings $appSettings -ConnectionStrings $connectionStrings

Write-Verbose ("[Finish] Adding settings to website {0}" -f $websiteName)

Write-Verbose ("[Finish] creating Windows Azure environment {0}" -f $Name)

# Write the environment info to an xml file so that the deploy script can consume
Write-Verbose "[Begin] writing environment info to environment.xml"
Generate-EnvironmentXml -EnvironmentName $Name -WebsiteName $websiteName `
    -StorageAccountName $storageAccountName -StorageAccountAccessKey $storageAccountAccessKey.Primary `
    -DatabaseServerName $sqlDatabaseServerName -DatabaseName $sqlDatabaseName -DatabaseUserName $SqlDatabaseUserName -DatabasePassword $SqlDatabasePassword
Write-Verbose ("{0}\environment.xml" -f $scriptPath)
Write-Verbose "[Finish] writing environment info to environment.xml"

# Generate the .pubxml file which will be used by webdeploy later
Write-Verbose ("[Begin] generating {0}.pubxml file" -f $websiteName)
Generate-PublishXml -Website $websiteName
Write-Verbose ("{0}\{1}.pubxml" -f $scriptPath, $websiteName )
Write-Verbose ("[Finish] generating {0}.pubxml file" -f $websiteName)

# Mark the finish time of the script execution
$finishTime = Get-Date
# Output the time consumed in seconds
Write-Output ("Total time used (seconds): {0}" -f ($finishTime - $startTime).TotalSeconds)

# End - Actual script -------------------------------------------------------------------------------------------------------------------------------