<#
    Title:          Azure Sentinel Log Ingestion - Process Log Queue Messages
    Language:       PowerShell
    Version:        1.1.0
    Author(s):      Sreedhar Ande, MF@CF
    Last Modified:  2025-03-07
    Comment:        Rebased Build


    DESCRIPTION
    This function monitors an Azure Storage queue for messages then retrieves the file and preps it for Ingestion processing.

    CHANGE HISTORY
    1.0.0 Inital release of code
    1.1.0 Spec change? required mods
#>
# $VerbosePreference = "Continue"

# Input bindings are passed in via param block.
param([object] $QueueItem, $TriggerMetadata)
# set queueitem as string, per Clippy. Object type introduced regression where expected input is null.
#param([string] $QueueItem, $TriggerMetadata)

# Get the current universal time in the default string format.
# unused.
#$currentUTCtime = (Get-Date).ToUniversalTime()

# Write out the queue message and metadata to the information log.
Write-Verbose "PowerShell queue trigger function processed work item: $QueueItem"
Write-Verbose "Queue item expiration time: $($TriggerMetadata.ExpirationTime)"
Write-Verbose "Queue item insertion time: $($TriggerMetadata.InsertionTime)"
Write-Verbose "Queue item next visible time: $($TriggerMetadata.NextVisibleTime)"
Write-Verbose "ID: $($TriggerMetadata.Id)"
Write-Verbose "Pop receipt: $($TriggerMetadata.PopReceipt)"
Write-Verbose "Dequeue count: $($TriggerMetadata.DequeueCount)"

#####Environment Variables
$AzureWebJobsStorage = $env:AzureWebJobsStorage
$AzureQueueName = $env:StgQueueName
$WorkspaceId = $env:WorkspaceId
$Workspacekey = $env:LogAnalyticsWorkspaceKey
$LATableName = $env:LATableName
$LAURI = $env:LAURI

# per doc, Log-Type must be alpha, which might mean custom_CL targets wont work?
# https://learn.microsoft.com/en-us/rest/api/loganalytics/create-request
# function Remove-NumeralsAndSpecialChars {
#     param (
#         [string]$inputString
#     )
#     $outputString = $inputString -replace '[^a-zA-Z]', ''
#     return $outputString
# }
# $sanitizedLATable = Remove-NumeralsAndSpecialChars($LATableName)

Write-Output "LAURI : $LAURI"

if($LAURI.Trim() -notmatch 'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$')
{
    Write-Error -Message "Storage Account Blobs Ingestion: Invalid Log Analytics Uri." -ErrorAction Stop
	Exit
}

Function Write-OMSLogfile {
    <#
    .SYNOPSIS
    Inputs a hashtable, date and workspace type and writes it to a Log Analytics Workspace.
    .DESCRIPTION
    Given a  value pair hash table, this function will write the data to an OMS Log Analytics workspace.
    Certain variables, such as Customer ID and Shared Key are specific to the OMS workspace data is being written to.
    This function will not write to multiple OMS workspaces.  Build-Signature and post-analytics function from Microsoft documentation
    at https://docs.microsoft.com/azure/log-analytics/log-analytics-data-collector-api
    .PARAMETER DateTime
    date and time for the log.  DateTime value
    .PARAMETER Type
    Name of the logfile or Log Analytics "Type".  Log Analytics will append _CL at the end of custom logs  String Value
    .PARAMETER LogData
    A series of key, value pairs that will be written to the log.  Log file are unstructured but the key should be consistent
    withing each source.
    .INPUTS
    The parameters of data and time, type and logdata.  Logdata is converted to JSON to submit to Log Analytics.
    .OUTPUTS
    The Function will return the HTTP status code from the Post method.  Status code 200 indicates the request was received.
    .NOTES
    Version:        2.0
    Author:         Travis Roberts
    Creation Date:  7/9/2018
    Purpose/Change: Crating a stand alone function
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [datetime]$dateTime,
        [parameter(Mandatory = $true, Position = 1)]
        [string]$type,
        [Parameter(Mandatory = $true, Position = 2)]
        [psobject]$logdata,
        [Parameter(Mandatory = $true, Position = 3)]
        [string]$CustomerID,
        [Parameter(Mandatory = $true, Position = 4)]
        [string]$SharedKey
    )

    Write-Verbose -Message "DateTime: $dateTime"
    Write-Verbose -Message ('DateTimeKind:' + $dateTime.kind)
    Write-Verbose -Message "Type: $type"
    Write-Verbose -Message "LogData: $logdata"

    # Supporting Functions
    # Function to create the auth signature
    Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
        $xHeaders = "x-ms-date:" + $date
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($sharedKey)
        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
        $sha256.Key = $keyBytes
        $calculatedHash = $sha256.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($calculatedHash)
        $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
        return $authorization
    }
    # Function to create and post the request
    Function Submit-LogAnalyticsData ($CustomerID, $SharedKey, $Body, $Type) {
        $method = "POST"
        $ContentType = 'application/json'
        $resource = '/api/logs'
        $rfc1123date = ($dateTime).ToString('r')
        $convertedDatetime = ($datetime).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $ContentLength = $Body.Length
        $signature = Build-Signature `
            -customerId $CustomerID `
            -sharedKey $SharedKey `
            -date $rfc1123date `
            -contentLength $ContentLength `
            -method $method `
            -contentType $ContentType `
            -resource $resource


		$uri = $LAURI.Trim() + $resource + "?api-version=2016-04-01"

        $headers = @{
            "Authorization"        = $signature;
            "Log-Type"             = $type;
            "x-ms-date"            = $rfc1123date;
            "time-generated-field" = $convertedDatetime;
        }
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $Body -UseBasicParsing -Verbose
        Write-Verbose -message ('Post Function Return Code ' + $response.statuscode)
        return $response.statuscode
    }

    # Check if time is UTC, Convert to UTC if not.
    # $dateTime = (Get-Date)
    if ($dateTime.kind.tostring() -ne 'Utc') {
        $dateTime = $dateTime.ToUniversalTime()
        Write-Verbose -Message ('UTC Time ' + $dateTime)
    }

    # Add DateTime to hashtable
    #$logdata.add("DateTime", $dateTime)
    $logdata | Add-Member -MemberType NoteProperty -Name "DateTime" -Value $dateTime

    #Build the JSON file
    $logMessage = ($logdata | ConvertTo-Json -Depth 20)
    Write-Verbose -Message ('Log Message ' + $logMessage)

    #Submit the data
    $returnCode = Submit-LogAnalyticsData -CustomerID $CustomerID -SharedKey $SharedKey -Body $logMessage -Type $type -Verbose
    Write-Verbose -Message "Post Statement Return Code $returnCode"
    return $returnCode
}

Function Submit-LogAnalyticsData ($corejson, $customLogName) {
    #Test Size; Log A limit is 30MB
    $tempdata = @()
    $tempDataSize = 0

    if ((($corejson |  Convertto-json -depth 20).Length) -gt 25MB) {
		Write-Host "Upload is over 25MB, needs to be split"
        foreach ($record in $corejson) {
            $tempdata += $record
            $tempDataSize += ($record | ConvertTo-Json -depth 20).Length
            if ($tempDataSize -gt 25MB) {
                Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $tempdata -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
                write-Host "Sending data = $TempDataSize"
                $tempdata = $null
                $tempdata = @()
                $tempDataSize = 0
            }
        }
        Write-Host "Sending left over data = $Tempdatasize"
        Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
    Else {
        #Send to Log A as is
        Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
}

#Build the JSON from queue
$QueueMsg = ConvertTo-Json $QueueItem -Depth 5 #-Compress -Verbose

$QueueArr = ConvertFrom-Json $QueueMsg;
$ResourceGroup = ($QueueArr.topic -split '/')[ 4 ]
$StorageAccountName = ($QueueArr.topic -split '/')[ -1 ]
$ContainerName = $QueueArr.subject.split('/')[4]
$BlobName = $QueueArr.subject.split('/')[-1]
$BlobURL = $QueueArr.data.url;

# ensure storage account exists and collect the context
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccountName -ErrorAction SilentlyContinue
if ($null -eq $storageAccount) {
    throw "The storage account specified does not exist in this subscription."
}
$storageContext = $storageAccount.Context
#New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

$blobContent = Get-AzStorageBlobContent -Uri $blobURL | ConvertTo-Json
$formalizedBlob = ( [System.Text.Encoding]::UTF8.GetBytes($blobContent))

$LAPostResult = Submit-LogAnalyticsData -Verbose -Corejson $formalizedBlob -CustomLogName $LATableName #$sanitizedLATable

if($LAPostResult -eq 200) {
    Write-Output ("Storage Account Blobs ingested into Azure Log Analytics Workspace Table")
    # Connect to Storage Queue to remove message on successful log processing
    $AzureStorage = New-AzStorageContext -ConnectionString $AzureWebJobsStorage
    $AzureQueue = Get-AzStorageQueue -Name $AzureQueueName -Context $AzureStorage
    $Null = $AzureQueue.CloudQueue.DeleteMessageAsync($TriggerMetadata.Id, $TriggerMetadata.popReceipt)
    Remove-AzStorageBlob -Context $context -Container $ContainerName -Blob $BlobName
    [System.GC]::collect() #cleanup memory
}
[System.GC]::GetTotalMemory($true) | out-null #Force full garbage collection - Powershell does not clean itself up properly in some situations
#end of Script