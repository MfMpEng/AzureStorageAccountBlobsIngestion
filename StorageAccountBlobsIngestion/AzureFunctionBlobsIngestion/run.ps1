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
# Input bindings are passed in via param block.
param([object] $QueueItem, $TriggerMetadata)
# $VerbosePreference = "Continue"
# Write out the queue message and metadata to the information log.
Write-Output "Current Directory: $(Get-Location)"
Write-Output "######################################################################################"
Write-Output "######################### BEGIN NEW TRANSACTION ######################################"
Write-Output "######################################################################################"
Write-Verbose "PowerShell queue trigger function processed work item: $QueueItem"
# Write-Verbose "Queue item expiration time: $($TriggerMetadata.ExpirationTime)"
# Write-Verbose "Queue item insertion time: $($TriggerMetadata.InsertionTime)"
# Write-Verbose "Queue item next visible time: $($TriggerMetadata.NextVisibleTime)"
Write-Verbose "ID: $($TriggerMetadata.Id)"
Write-Verbose "Pop receipt: $($TriggerMetadata.PopReceipt)"
# Write-Verbose "Dequeue count: $($TriggerMetadata.DequeueCount)"
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
    # Write-Verbose -Message "DateTime: $dateTime"
    # Write-Verbose -Message ('DateTimeKind:' + $dateTime.kind)
    # Write-Verbose -Message "Type: $type"
    # Write-Verbose -Message "LogData: $logdata"
#
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
    Function Submit-OMSPostReq ($CustomerID, $SharedKey, $Body, $Type) {
        $method = "POST"
        $ContentType = 'application/json'
        $resource = '/api/logs'
        $rfc1123date = (Get-Date).ToString('r')
        $utcEvtTime = $datetime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
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
            "time-generated-field" = $utcEvtTime;
        }
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $Body -UseBasicParsing -Verbose
        Write-Verbose -message ('Post Function Return Code ' + $response.statuscode)
        return $response.statuscode
    }
    # # Check if time is UTC, Convert to UTC if not.
    # # $dateTime = (Get-Date)
    # if ($dateTime.kind.tostring() -ne 'Utc') {
    #     $utcTime = $dateTime.ToUniversalTime()
    #     Write-Verbose -Message ('UTC Time ' + $dateTime)
    # }
    # Add DateTime to hashtable
    #$logdata.add("DateTime", $dateTime)
    $logdata | Add-Member -MemberType NoteProperty -Name "DateTime" -Value $evtTime
    #Build the JSON file
    $logMessage = ($logdata | ConvertTo-Json -Depth 20)
    Write-Verbose -Message ('Log Message ' + $logMessage)
    #Submit the data
    $returnCode = Submit-OMSPostReq -CustomerID $CustomerID -SharedKey $SharedKey -Body $logMessage -Type $type -Verbose
    Write-Verbose -Message "Post Statement Return Code $returnCode"
    return $returnCode
}

Function Submit-ChunkLAdata ($corejson, $customLogName) {
    #Test Size; Log A limit is 30MB
    $tempdata = @()
    $tempDataSize = 0
    if ((($corejson |  ConvertTo-Json -depth 20).Length) -gt 25MB) {
		Write-Host "Upload is over 25MB, needs to be split"
        foreach ($record in $corejson) {
            $tempdata += $record
            $tempDataSize += ($record | ConvertTo-Json -depth 20).Length
            if ($tempDataSize -gt 25MB) {
                Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $tempdata -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
                write-Host "Sending data = $TempDataSize"
                $tempdata = $null
                $tempdata = @()
                $tempDataSize = 0
            }
        }
        Write-Host "Sending left over data = $Tempdatasize"
        Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
    Else {
        #Send to Log A as is
        Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
}

# Function Convert-SemicolonToURLEncoding([String] $InputText) {
#     $ReturnText = ""
#     $chars = $InputText.ToCharArray()
#     $StartConvert = $false
#     foreach ($c in $chars) {
#         if ($c -eq '"') {
#             $StartConvert = ! $StartConvert
#         }
#         if ($StartConvert -eq $true -and $c -eq ';') {
#             $ReturnText += "%3B"
#         }
#         else {
#             $ReturnText += $c
#         }
#     }
#     return $ReturnText
# }

# Function ConvertTo-JsonValue($Text) {
#     $Text1 = ""
#     if ($Text.IndexOf("`"") -eq 0) { $Text1 = $Text } else { $Text1 = "`"" + $Text + "`"" }
#     if ($Text1.IndexOf("%3B") -ge 0) {
#         $ReturnText = $Text1.Replace("%3B", ";")
#     }
#     else {
#         $ReturnText = $Text1
#     }
#     return $ReturnText
# }

# Function Convert-LogLineToJson([String] $logLine) {
#     #Convert semicolon to %3B in the log line to avoid wrong split with ";"
#     $logLineEncoded = Convert-SemicolonToURLEncoding($logLine)
#     $elements = $logLineEncoded.split(';')
#     $FormattedElements = New-Object System.Collections.ArrayList
#     foreach ($element in $elements) {
#         # Validate if the text starts with ", and add it if not
#         $NewText = ConvertTo-JsonValue($element)
#         # Use "> null" to avoid annoying index print in the console
#         $FormattedElements.Add($NewText) > null
#     }
#     $Columns =
#     ("F5_timestamp_CF",
#     "F5_id_CF",
#     "F5_visitor_id_CF",
#     "action_CF",
#     "api_endpoint_CF",
#     "app_CF",
#     "app_type_CF",
#     "as_number_CF",
#     "as_org_CF",
#     "asn_CF",
#     "attack_types_CF",
#     "authority_CF",
#     "bot_info_CF",
#     "browser_type_CF",
#     "calculated_action_CF",
#     "city_CF",
#     "cluster_name_CF",
#     "country_CF",
#     "dcid_CF",
#     "detections_CF",
#     "device_type_CF",
#     "domain_CF",
#     "dst_CF",
#     "dst_instance_CF",
#     "dst_ip_CF",
#     "dst_port_CF",
#     "dst_site_CF",
#     "excluded_threat_campaigns_CF",
#     "hostname_CF",
#     "http_version_CF",
#     "is_new_dcid_CF",
#     "is_truncated_field_CF",
#     "kubernetes_CF",
#     "latitude_CF",
#     "longitude_CF",
#     "messageid_CF",
#     "method_CF",
#     "namespace_CF",
#     "network_CF",
#     "no_active_detections_CF",
#     "original_headers_CF",
#     "original_path_CF",
#     "path_CF",
#     "region_CF",
#     "req_headers_CF",
#     "req_headers_size_CF",
#     "req_id_CF",
#     "req_params_CF",
#     "req_path_CF",
#     "req_size_CF",
#     "rsp_code_CF",
#     "rsp_code_class_CF",
#     "rsp_size_CF",
#     "sec_event_name_CF",
#     "sec_event_type_CF",
#     "severity_CF",
#     "signatures_CF",
#     "site_CF",
#     "sni_CF",
#     "src_CF",
#     "src_instance_CF",
#     "src_ip_CF",
#     "src_port_CF",
#     "src_site_CF",
#     "stream_CF",
#     "tag_CF",
#     "tenant_CF",
#     "threat_campaigns_CF",
#     "time_CF",
#     "tls_fingerprint_CF",
#     "user_CF",
#     "user_agent_CF",
#     "vh_name_CF",
#     "vhost_id_CF",
#     "violation_details_CF",
#     "violation_rating_CF",
#     "violations_CF",
#     "waf_mode_CF",
#     "x_forwarded_for_CF"
#     )
#     # Propose json payload
#     $logJson = "[{";
#     For ($i = 0; $i -lt $Columns.Length; $i++) {
#         $logJson += "`"" + $Columns[$i] + "`":" + $FormattedElements[$i]
#         if ($i -lt $Columns.Length - 1) {
#             $logJson += ","
#         }
#     }
#     $logJson += "}]";
#     return $logJson
# }

#Build the JSON from queue and grab blob path vars
$QueueMsg           = ConvertTo-Json $QueueItem -Depth 20 #-Compress -Verbose
$QueueArr           = @(ConvertFrom-Json $QueueMsg);
# $ResourceGroup      = $QueueArr.topic.split('/')[4]
$StorageAccountName = $QueueArr.topic.split('/')[-1]
$ContainerName      = $QueueArr.subject.split('/')[4]
$BlobName           = $QueueArr.subject.split('/')[-1]
#$BlobPath           = $QueueArr.subject.tostring()
$BlobPath           = $QueueArr.subject.split('/')[6..($QueueArr.subject.split('/').Length - 1)] -join '/'
$BlobURL            = $QueueArr.data.url.tostring()
$evtTime            = $QueueArr.eventTime
Write-Output "$evtTime Queue Reported $StorageAccountName\$ContainerName\$BlobName`nat $BlobURL"
# import-module az.storage
$AzureStorage = New-AzStorageContext -ConnectionString $AzureWebJobsStorage
$logPath = [System.IO.Path]::Combine($env:TEMP, $BlobName)
# Get-AzStorageBlobContent -Context $AzureStorage -Container $ContainerName -Blob $BlobPath -Destination $logPath -force > $null
try {
    Write-Output "Attempting to download blob content..."
    Get-AzStorageBlobContent -Context $AzureStorage -Container $ContainerName -Blob $BlobPath -Destination $logPath -Force |out-null
    Write-Output "Blob content downloaded to $logPath"
}
catch {
    Write-Output "Error downloading blob content: $_"
}
$logsFromFile = Get-Content -Path $logPath -raw |ConvertFrom-Json
# foreach ($log in $logsFromFile) {
    # $json = Convert-LogLineToJson($log)
    # $formalizedJson = ( [System.Text.Encoding]::UTF8.GetBytes($json))
    $LAPostResult = Submit-ChunkLAdata -Verbose -Corejson $logsFromFile -CustomLogName $LATableName #$sanitizedLATable
    if($LAPostResult -eq 200) {
        Write-Output ("Storage Account Blobs ingested into Azure Log Analytics Workspace Table $LATableName")
        # Connect to Storage Queue to remove message on successful log processing
        $AzureQueue = Get-AzStorageQueue -Name $AzureQueueName -Context $AzureStorage
        $Null = $AzureQueue.CloudQueue.DeleteMessageAsync($TriggerMetadata.Id, $TriggerMetadata.popReceipt)
        Remove-Item $logPath
        # if ($null -ne $AzureQueueName -and $null -ne $TriggerMetadata -and $null -ne $TriggerMetadata.Id -and $null -ne $TriggerMetadata.popReceipt) {
            # $AzureQueue.CloudQueue.DeleteMessageAsync($TriggerMetadata.Id, $TriggerMetadata.popReceipt)
        # }
        # else {
            # Write-Host "Unable to DeQueue Item: CloudQueue='${AzureQueueName.CloudQueue}' TriggerMetadata: '$TriggerMetadata'"
        # }
        Remove-AzStorageBlob -Context $AzureStorage -Container $ContainerName -Blob $BlobPath
        [System.GC]::collect() #cleanup memory
    }
# }
Write-Output "######################################################################################"
Write-Output "############################ END TRANSACTION #########################################"
Write-Output "######################################################################################"
[System.GC]::GetTotalMemory($true) | out-null #Force full garbage collection - Powershell does not clean itself up properly in some situations
#end of Script