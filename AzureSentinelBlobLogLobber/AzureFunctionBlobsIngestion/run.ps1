<#
    .DESCRIPTION
        This function monitors an Azure Storage Queue for Block Blob Write Messages, then retrieves the Blob and preps it for POST submission to
    .INPUTS
        Storage Queue Blob Write messages
    .OUTPUTS
        Azure Monitor HTTP REST API JSON POST request, (soon) Logs Ingestion API POST request
    .LINK
        08/08/2023 https://learn.microsoft.com/en-us/previous-versions/azure/azure-monitor/logs/data-collector-api?tabs=powershell
        05/07/2024 https://learn.microsoft.com/en-us/rest/api/loganalytics/create-request
        09/11/2024 https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/errors
        09/11/2024 https://learn.microsoft.com/en-us/azure/azure-monitor/logs/custom-logs-migrate
    .NOTES
        Title:          Azure Sentinel Blob Log Lobber - Process Json Blobs via Storage Queue Messages
        Language:       PowerShell
        Version:        1.5.1
        Author(s):      MF@CF,Sreedhar Ande, Travis Roberts, kozhemyak
        Last Modified:  2025-03-14
        Comment:        Migration to Log Ingestion API - Deprecation notice: The Azure Monitor HTTP Data Collector API
                        has been deprecated and will no longer be functionalas of 9/14/2026. It's been replaced by the
                        Logs ingestion API. [.LINK 1]
        CHANGE HISTORY
        1.0.0 Inital release of code
        1.5.0 Submits blob content not queue message
        2.0.0 Options to Use Log Ingestion API
        TODO
        - Convert DCR/LI function into a chunking wrapper like the LA Data Collector
        - ARM template the direct-endpoint DCR and an EntApp Registration
        - parameterize json param name hashtable
#>
# Input bindings are passed in via param block.
param( [object]$QueueItem, [object]$TriggerMetadata )
# $VerbosePreference = "Continue"
# $QueueItem = [PSObject]::AsPSObject($QueueItem)
# $TriggerMetadata = [PSObject]::AsPSObject($TriggerMetadata)
#####Env Vars
$LAURI = $env:LAURI
$AzureWebJobsStorage = $env:AzureWebJobsStorage
$LATableName = $env:LATableName
$StgQueueName = $env:StgQueueName
$WorkspaceId = $env:WorkspaceId
$Workspacekey = $env:LogAnalyticsWorkspaceKey
# TODO: ARM with DCR/DCE and EntApp
$DCE = $env:DCE
$tenantId = $env:tenantId
$DCEEntAppId = $env:DCEEntAppId
$DCEEntAppRegKey = $env:DCEEntAppRegKey
##### Init vars
# $ResourceGroup      = $QueueArr.topic.split('/')[4]
$QueueMsg = ConvertTo-Json $QueueItem -depth 4
$QueueArr = @(ConvertFrom-Json $QueueMsg);
$StorageAccountName = $QueueArr.topic.split('/')[-1]
$ContainerName = $QueueArr.subject.split('/')[4]
$BlobPath = $QueueArr.subject.split('/')[6..($QueueArr.subject.split('/').Length - 1)] -join '/'
$BlobName = $QueueArr.subject.split('/')[-1]
$BlobCType = $QueueArr.data.contentType #application/x-ndjson
$BlobType = $QueueArr.data.blobType # BlockBlob
$BlobEncoding = $QueueArr.data.contentEncoding # gzip
$evtTime = $QueueArr.eventTime
$QueueID = $TriggerMetadata.Id
$QueuePOP = $TriggerMetadata.PopReceipt
$AzureStorage = New-AzStorageContext -ConnectionString $AzureWebJobsStorage
$logPath = [System.IO.Path]::Combine($env:TEMP, $BlobName)
$skipfile = $false;
# $actorIP = Invoke-RestMethod -Uri "https://ifconfig.me/ip"
$DCEbaseURI = $DCE.split('?')[0]
$DCETable = $DCEbaseURI.split('/')[-1]
##### Fn Defs
# App Insights Authenticator
Function Set-AppInsightsID {
    # Create a DefaultAzureCredential
    $credential = [Azure.Identity.DefaultAzureCredential]::new()
    # Create a new OpenTelemetry tracer provider and set the credential
    $tracerProvider = [OpenTelemetry.Sdk]::CreateTracerProviderBuilder()
    $tracerProvider.AddAzureMonitorTraceExporter([OpenTelemetry.Exporter.AzureMonitorTraceExporterOptions]::new($credential))
    $tracerProvider.Build()
    # Create a new OpenTelemetry meter provider and set the credential
    $metricsProvider = [OpenTelemetry.Sdk]::CreateMeterProviderBuilder()
    $metricsProvider.AddAzureMonitorMetricExporter([OpenTelemetry.Exporter.AzureMonitorMetricExporterOptions]::new($credential))
    $metricsProvider.Build()
    # Create a new logger factory and add the OpenTelemetry logger provider with the credential
    $loggerFactory = [Microsoft.Extensions.Logging.LoggerFactory]::Create([Microsoft.Extensions.Logging.LoggerFactoryOptions]::new())
    $loggerFactory.AddOpenTelemetry([OpenTelemetry.Logging.OpenTelemetryLoggerOptions]::new($credential))
    # Return the created objects as a custom object
    return [PSCustomObject]@{
        Credential      = $credential
        TracerProvider  = $tracerProvider
        MetricsProvider = $metricsProvider
        LoggerFactory   = $loggerFactory
    }
}
# Code Wrapper
Function Write-LogHeader() {
    # Write out the queue message and metadata to the information log.
    # Write-Host ("######################################################################################")
    Write-Host ("######################### BEGIN NEW TRANSACTION ######################################")
    Write-Host ("################# $BlobName ################")
    # Write-Host ("######################################################################################")
    # Write-Host ("Dequeue count               :" + $TriggerMetadata.DequeueCount)
    # Write-Host ("PowerShell queue trigger function processed work item:" + $QueueItem)
    # Write-Host ("Log Analytics URI           :" + $LAURI)
    Write-Host ("Log Ingestion URI           :`n" + $DCE)
    # Write-Host ("This Fn App Host outbound IP: " + $actorIP)
    # Write-Host ("Queue Message ID            :" + $QueueId)
    # Write-Host ("Queue Message Pop receipt   :" + $QueuePOP)
    # Write-Host ("Current Directory           :" + $(Get-Location))
    # Write-Host ("Queue item expiration time  :" + $TriggerMetadata.ExpirationTime)
    # Write-Host ("Queue item insertion time   :" + $TriggerMetadata.InsertionTime)
    # Write-Host ("Queue item next visible time:" + $TriggerMetadata.NextVisibleTime)
    # Write-Host ("$evtTime Queue Reported new item - BlobName:  $BlobName")
}
# Code Wrapper
Function Write-LogFooter() {
    # Write-Host ("######################################################################################")
    Write-Host ("############################ END TRANSACTION #########################################")
    Write-Host ("################# $BlobName ################")
    # Write-Host ("######################################################################################")
}
# Input Cleaner
Function Remove-AzStorageQueueMessage([string]$StorageAccountName, [string]$queueName, [string]$messageId, [string]$popReceipt, [string]$connectionString) {
    # extract SA key and struct body
    #supporting function
    Function Submit-StgAcctDelReq ($StgAcctName, $queueName, $SharedKey, $Body, $uri) {
        # struct headers and RPC
        $method = "DELETE"
        $ContentLength = $Body.Length
        $ContentType = 'text/html; charset=utf-8'
        $rfc1123date = (Get-Date).ToString('R')
        $signature = Build-Signature -CustomerID $StgAcctName -SharedKey $SharedKey -Date $rfc1123date `
        -ContentLength $ContentLength -method $method -ContentType $ContentType -resource $resource
        $headers = @{
            "Authorization" = $signature;
            "x-ms-date"     = $rfc1123date;
        }
        try {
                $response = Invoke-WebRequest -Uri $uri -Method $method -Headers $headers -ContentType $ContentType -Body $Body
                $QdelResp = $response.statuscode
                Write-Host -Message ('Storage Queue Delete Result ' + $QdelResp)
        } catch {
                Write-Error ("Queue Delete Status Code:" + $_.Exception.Type + " " + $_.Exception.ScriptStackTrace)
                $QdelResp = $_.Exception.Message
                Write-Error ("Queue Delete Status Description:" + $_.Exception.CategoryInfo)
            }
        return $QdelResp
    }
    # Extract the storage account name and key from the connection string
    $connectionStringParts = $connectionString -split ";"
    # $storageAccountName = ($connectionStringParts | Where-Object { $_ -like "AccountName*" }) -split "=" | Select-Object -Last 1
    $storageAccountKey = ($connectionStringParts | Where-Object { $_ -like "AccountKey*" }) -split "=" | Select-Object -Last 1
    #$stringToHash = "DELETE`n`n`n`n`n`n`n`n`n`n`n`n`n$rfc1123date`n/$storageAccountName$resource?popreceipt=$popReceipt"
    $resource = "/$queueName/messages/$messageId"
    $param = "?popreceipt=$popReceipt"
    $uri = "https://$StorageAccountName.queue.core.windows.net" + $resource + $param
    # call the wrapper for Build-Headers
    $resp = Submit-StgAcctDelReq -StgAcctName $StorageAccountName -queueName $queueName `
    -SharedKey $storageAccountKey -Body $resource+$param -uri $uri
    return $resp
}
# Output Constructor (Write-LAlogFile(Submit-LAlogFile), Remove-AzStorageQueueMessage)
Function Build-Signature ($CustomerID, $SharedKey, $Date, $ContentLength, $method, $ContentType, $resource) {
    # Function creates the Authorization signature header value
    $xheaders = 'x-ms-date:' + $Date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
    $bytesToHash = [text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($SharedKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.key = $keyBytes
    $calculateHash = $sha256.ComputeHash($bytesToHash)
    $encodeHash = [convert]::ToBase64String($calculateHash)
    $authorization = 'SharedKey {0}:{1}' -f $CustomerID, $encodeHash
    return $authorization
    # $signature = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($SharedKey))
    # $bytesToHashconv = [System.Text.Encoding]::UTF8.GetBytes("$contentType`n$Data")
    # $hashed = $signature.ComputeHash($bytesToHashconv)
    # $encoded = [System.Convert]::ToBase64String($hashed)
    # return $encoded
}
#Output Handler
Function Submit-LogIngestion ( [string]$DCE, [string]$DCEEntAppId, [string]$DCEEntAppRegKey, [string]$tenantId, [string]$Body) {
    #supporting function
    Function Get-EntAppBearerToken ([string]$EntAppId, [string]$EntAppSecret, [string]$AzTenantId) {
        # input construct
        $scope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")
        $uri = "https://login.microsoftonline.com/$AzTenantId/oauth2/v2.0/token"
        $method = "Post"
        $contentType = 'application/x-www-form-urlencoded'
        $body = "client_id=$EntAppId&scope=$scope&client_secret=$EntAppSecret&grant_type=client_credentials";
        $PlainToken = (Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Body $body).access_token
        # -token only accepts [secureString]
        $BearerToken = ConvertTo-SecureString $PlainToken -AsPlainText -Force
        return $BearerToken
    }
    # Write-Error "Env Vars missing details for DCR Submission"
    $SstrToken = Get-EntAppBearerToken -EntAppId $DCEEntAppId -EntAppSecret $DCEEntAppRegKey -AzTenantId $tenantId
    $DCEmethod = 'Post'
    $DCEcontentType = 'application/json'
    $DCEauthType = 'Bearer'
    try {
        $response = Invoke-WebRequest -Uri $DCE -Method $DCEmethod -ContentType $DCEcontentType `
            -Authentication $DCEauthType -Token $SstrToken -Body $Body
        $DCEpostStatus = $response.statusCode
    }
    catch {
        # Write-Error ("LI/DCE Submit Status Code:" + $_.Exception.Type + " " + $_.Exception.ScriptStackTrace)
        $DCEpostStatus = $_.Exception.Message
        Write-Error $_.Exception
        # Write-Error ("LI/DCE Submit Status Description:" + $_.Exception.CategoryInfo)
    }
    return $DCEpostStatus
}
# Output Handler Helper
Function Write-LAlogFile {
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
        [object]$logdata,
        [Parameter(Mandatory = $true, Position = 3)]
        [string]$CustomerID,
        [Parameter(Mandatory = $true, Position = 4)]
        [string]$SharedKey
    )
    # Output Handler
    Function Submit-LApostRequest ([string]$CustomerID, [string]$SharedKey, [string]$Body, [string]$Type) {
        # Function generates HTTP header/body and POST it
        [cmdletbinding()]
        $method = "POST"
        $ContentType = 'application/json'
        $resource = '/api/logs'
        $rfc1123date = (Get-Date).ToString('R')
        $Iso8601ZventTime = $datetime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $ContentLength = $Body.Length
        $signature = Build-Signature -CustomerID $CustomerID -SharedKey $SharedKey -Date $rfc1123date `
        -ContentLength $ContentLength -method $method -ContentType $ContentType -resource $resource
        $uri = $LAURI.Trim() + $resource + "?api-version=2016-04-01"
        $headers = @{
            "Authorization"        = $signature;
            "x-ms-date"            = $rfc1123date;
            "Log-Type"             = $type;
            "time-generated-field" = $Iso8601ZventTime;
        }
        try {
            $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $body
            $ODSresponseCode = $response.StatusCode
        }catch{
            Write-Error ("LA/ODS Status Code:" + $_.Exception.Type + " " + $_.Exception.ScriptStackTrace)
            $ODSresponseCode = $_.Exception.Message
            Write-Error ("LA/ODS Status Description:" + $_.Exception.CategoryInfo)
        }
        return $ODSresponseCode
    }
    $returnCode = Submit-LApostRequest -CustomerID $CustomerID -SharedKey $SharedKey -Body $logdata -Type $type
    return $returnCode
}
# Output Wrapper(Write-LAlogFile)
Function Submit-ChunkLAdata ([string]$corejson, [string]$customLogName) {
    #Wrapper for Write-LAlogFile to chunk based on REST API limit spec. Max 30Mb, this cuts at 25.
    $tempdata = @()
    $tempDataSize = 0
    if ((($corejson |  ConvertTo-Json -depth 2).Length) -gt 25MB) {
		Write-Host -Message ("Upload is over 25MB, needs to be split")
        foreach ($record in $corejson) {
            $tempdata += $record
            $tempDataSize += ($record | ConvertTo-Json -depth 2).Length
            if ($tempDataSize -gt 25MB) {
                $ret = Write-LAlogFile -dateTime $evtTime -type $customLogName -logdata $tempdata -CustomerID $workspaceId -SharedKey $workspaceKey
                Write-Host "Sending dataset = $TempDataSize"
                $tempdata = $null
                $tempdata = @()
                $tempDataSize = 0
            }
        }
        Write-Host "Sending left over data = $Tempdatasize"
        $ret = Write-LAlogFile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey
    }
    Else {
        #Send to Log A as is
        $ret = Write-LAlogFile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey
    }
    return $ret
}
# Input Parser
# Function Convert-LogLineToJson([String] $logLine) {
#     <#useful if log source does not provide explicit json, only a csv of property values to reconstruct
#         .LINK
#             https://github.com/Azure/azure-docs-powershell-samples/blob/master/storage/post-storage-logs-to-log-analytics/PostStorageLogs2LogAnalytics.ps1#L3
#         supporting Functions
#     #>
#     Function Convert-SemicolonToURLEncoding([String] $InputText) {
#         $ReturnText = ""
#         $chars = $InputText.ToCharArray()
#         $StartConvert = $false
#         foreach ($c in $chars) {
#             if ($c -eq '"') {
#                 $StartConvert = ! $StartConvert
#             }
#             if ($StartConvert -eq $true -and $c -eq ';') {
#                 $ReturnText += "%3B"
#             }
#             else {
#                 $ReturnText += $c
#             }
#         }
#         return $ReturnText
#     }
#     Function ConvertTo-JsonValue($Text) {
#         $Text1 = ""
#         if ($Text.IndexOf("`"") -eq 0) { $Text1 = $Text } else { $Text1 = "`"" + $Text + "`"" }
#         if ($Text1.IndexOf("%3B") -ge 0) {
#             $ReturnText = $Text1.Replace("%3B", ";")
#         }
#         else {
#             $ReturnText = $Text1
#         }
#         return $ReturnText
#     }
#     #Convert semicolon to %3B in the log line to avoid wrong split with ";"
#     $logLineEncoded = Convert-SemicolonToURLEncoding($logLine)
#     $elements = $logLineEncoded.split(';')
#     $FormattedElements = New-Object System.Collections.ArrayList
#     foreach ($element in $elements) {
#         # Validate if the text starts with ", and add it if not
#         $NewText = ConvertTo-JsonValue($element)
#         # Use "> null" to avoid annoying index print in the console
#         $FormattedElements.Add($NewText) |out-null
#     }
#     $Columns = ("col1", "col2")
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
# Input Parser
Function Build-ChaffedSortedJsonProps ([Parameter(Mandatory = $true)][string]$rawJson) {
    # Custom property name dictionary
    [hashtable]$logToTablePropNames = [ordered]@{
        "@timestamp"                       = "F5_timestamp";
        "_id"                              = "F5_id";
        "_visitor_id"                      = "F5_visitor_id";
        "time"                             = "F5_time";
        "content-type"                     = "F5_content_type";
        "accept"                           = "F5_accept"
        "action"                           = "F5_action";
        "api_endpoint"                     = "F5_api_endpoint";
        "app"                              = "F5_app";
        "app_firewall_name"                = "F5_app_firewall_name";
        "app_type"                         = "F5_app_type";
        "as_number"                        = "F5_as_number";
        "as_org"                           = "F5_as_org";
        "asn"                              = "F5_asn";
        "attack_types"                     = "F5_attack_types";
        "authority"                        = "F5_authority";
        "bot_class"                        = "F5_bot_class"
        "bot_info"                         = "F5_bot_info";
        "browser_type"                     = "F5_browser_type";
        "calculated_action"                = "F5_calculated_action";
        "city"                             = "F5_city";
        "cluster_name"                     = "F5_cluster_name";
        "connected_time"                   = "F5_connected_time"
        "connection_state"                 = "F5_connection_state"
        "country"                          = "F5_country";
        "dcid"                             = "F5_dcid";
        "detections"                       = "F5_detections";
        "device_type"                      = "F5_device_type";
        "domain"                           = "F5_domain";
        "dst"                              = "F5_dst";
        "dst_instance"                     = "F5_dst_instance";
        "dst_ip"                           = "F5_dst_ip";
        "dst_port"                         = "F5_dst_port";
        "dst_site"                         = "F5_dst_site";
        "duration_with_data_tx_delay"      = "F5_duration_with_data_tx_delay"
        "duration_with_no_data_tx_delay"   = "F5_duration_with_no_data_tx_delay"
        "enforcement_mode"                 = "F5_enforcement_mode";
        "excluded_threat_campaigns"        = "F5_excluded_threat_campaigns";
        "has_sec_event"                    = "F5_has_sec_event"
        "hostname"                         = "F5_hostname";
        "http_version"                     = "F5_http_version";
        "is_new_dcid"                      = "F5_is_new_dcid";
        "is_truncated_field"               = "F5_is_truncated_field";
        "ja4_tls_fingerprint"              = "F5_ja4_tls_fingerprint";
        "kubernetes"                       = "F5_kubernetes";
        "latitude"                         = "F5_latitude";
        "lb_port"                          = "F5_lb_port"
        "longitude"                        = "F5_longitude";
        "messageid"                        = "F5_messageid";
        "method"                           = "F5_method";
        "mtls"                             = "F5_mtls"
        "namespace"                        = "F5_namespace";
        "network"                          = "F5_network";
        "no_active_detections"             = "F5_no_active_detections";
        "node_id"                          = "F5_node_id"
        "origin"                           = "F5_origin"
        "original_authority"               = "F5_original_authority"
        "original_headers"                 = "F5_original_headers";
        "original_path"                    = "F5_original_path";
        "original_referer"                 = "F5_original_referer";
        "path"                             = "F5_path";
        "policy_hits"                      = "F5_policy_hits"
        "protocol"                         = "F5_protocol"
        "proxy_type"                       = "F5_proxy_type"
        "recommended_action"               = "F5_recommended_action";
        "referer"                          = "F5_referer"
        "region"                           = "F5_region";
        "req_headers"                      = "F5_req_headers";
        "req_headers_size"                 = "F5_req_headers_size";
        "req_id"                           = "F5_req_id";
        "req_params"                       = "F5_req_params";
        "req_path"                         = "F5_req_path";
        "req_size"                         = "F5_req_size";
        "response_flags"                   = "F5_response_flags"
        "rsp_code"                         = "F5_rsp_code";
        "rsp_code_class"                   = "F5_rsp_code_class";
        "rsp_code_details"                 = "F5_rsp_code_details"
        "rsp_headers"                      = "F5_rsp_headers"
        "rsp_size"                         = "F5_rsp_size";
        "rtt_downstream_seconds"           = "F5_rtt_downstream_seconds"
        "rtt_upstream_seconds"             = "F5_rtt_upstream_seconds"
        "sample_rate"                      = "F5_sample_rate"
        "scheme"                           = "F5_scheme"
        "sec_event_name"                   = "F5_sec_event_name";
        "sec_event_type"                   = "F5_sec_event_type";
        "severity"                         = "F5_severity";
        "signatures"                       = "F5_signatures";
        "site"                             = "F5_site";
        "sni"                              = "F5_sni";
        "src"                              = "F5_src";
        "src_instance"                     = "F5_src_instance";
        "src_ip"                           = "F5_src_ip";
        "src_port"                         = "F5_src_port";
        "src_site"                         = "F5_src_site";
        "stream"                           = "F5_stream";
        "tag"                              = "F5_tag";
        "tenant"                           = "F5_tenant";
        "terminated_time"                  = "F5_terminated_time"
        "threat_campaigns"                 = "F5_threat_campaigns";
        "time_to_first_downstream_tx_byte" = "F5_time_to_first_downstream_tx_byte"
        "time_to_first_upstream_rx_byte"   = "F5_time_to_first_upstream_rx_byte"
        "time_to_first_upstream_tx_byte"   = "F5_time_to_first_upstream_tx_byte"
        "time_to_last_downstream_tx_byte"  = "F5_time_to_last_downstream_tx_byte"
        "time_to_last_rx_byte"             = "F5_time_to_last_rx_byte"
        "time_to_last_upstream_rx_byte"    = "F5_time_to_last_upstream_rx_byte"
        "time_to_last_upstream_tx_byte"    = "F5_time_to_last_upstream_tx_byte"
        "timeseries_enabled"               = "F5_timeseries_enabled"
        "tls_cipher_suite"                 = "F5_tls_cipher_suite"
        "tls_fingerprint"                  = "F5_tls_fingerprint";
        "tls_version"                      = "F5_tls_version"
        "user"                             = "F5_user";
        "user_agent"                       = "F5_user_agent";
        "vh_name"                          = "F5_vh_name";
        "vh_type"                          = "F5_vh_type"
        "vhost_id"                         = "F5_vhost_id";
        "violation_details"                = "F5_violation_details";
        "violation_rating"                 = "F5_violation_rating";
        "violations"                       = "F5_violations";
        "waf_action"                       = "F5_waf_action"
        "waf_mode"                         = "F5_waf_mode";
        "x_forwarded_for"                  = "F5_x_forwarded_for";

    }
    Function New-SortedJsonProperties ([Parameter(Mandatory = $true)][PSCustomObject]$modjson) {
        # Convert the JSON PSObject to a hashtable
        $jsonHashTable = @{}
        $modjson.PSObject.Properties | ForEach-Object {
            $jsonHashTable[$_.Name] = $_.Value
        }
        # Sort the hashtable by keys
        $sortedHashTable = $jsonHashTable.GetEnumerator() | Sort-Object Name
        # Convert the sorted hashtable back to a JSON PSObject
        $sortedJsonObject = [PSCustomObject]@{}
        $sortedHashTable | ForEach-Object {
            $sortedJsonObject | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
        }
        return $sortedJsonObject
    }
    Function Add-MissingProperties ([Parameter(Mandatory = $true)][psobject]$modJson, [hashtable]$logToTablePropNames) {
        foreach ($newName in $logToTablePropNames.Values) {
            if (-not $modJson.PSObject.Properties.Name.Contains($newName)) {
                $modJson | Add-Member -MemberType NoteProperty -Name $newName -Value ""
            }
        }
        return $modJson
    }
    Function Resolve-EscapedJsonSubarrays ([Parameter(Mandatory = $true)][psobject]$modJson) {
        try {
            $modJson.req_headers = $modJson.req_headers | ConvertFrom-Json
        }
        catch {}
        try {
            $modJson.original_headers = $modJson.original_headers | ConvertTo-Json -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {}
        return $modJson
    }
    Function Resolve-JsonPropertyNames ([Parameter(Mandatory = $true)][psobject]$modjson) {
        foreach ($jsonProp in $modJson.PSObject.Properties) {
            $oldName = $jsonProp.Name
            if ($logToTablePropNames.ContainsKey($oldName)) {
                $newName = $logToTablePropNames[$oldName]
                $modJson | Add-Member -MemberType NoteProperty -Name $newName -Value $jsonProp.Value -Force
                $modJson.PSObject.Properties.Remove($oldName)
            }
        }
        return $modjson
    }
    $modJson = $rawJson | ConvertFrom-Json
    Write-Output "#################modJson`n" $modJson
    $escapedJson = Resolve-EscapedJsonSubarrays -modJson $modJson
    Write-Output "#################escapedJson`n" $escapedJson
    $escapedJson | Add-Member -MemberType NoteProperty -Name "TimeGenerated" -Value $escapedJson."@timestamp" -Force
    $namedJson = Resolve-JsonPropertyNames -modjson $escapedJson
    Write-Output "#################namedJson`n" $namedJson
    $chaffedJson = Add-MissingProperties -modJson $namedJson -logToTablePropNames $logToTablePropNames
    Write-Output "#################chaffedJson`n" $chaffedJson
    $sortedJson = New-SortedJsonProperties -modjson $chaffedJson
    Write-Output "#################sortedJson`n" $sortedJson
    $stringedJson = $sortedJson | ConvertTo-Json -Depth 2
    return $stringedJson
}
# Input Parser
Function Remove-InvalidProperties ([Parameter(Mandatory = $true)][string]$JsonString) {
    # Convert JSON string to a PowerShell object
    $jsonObject = $JsonString | ConvertFrom-Json
    # append required field
    $jsonObject | Add-Member -MemberType NoteProperty -Name "TimeGenerated" -Value $jsonObject."@timestamp" -Force
    #fix json subarrays
    $req_headers = $jsonObject.req_headers | ConvertFrom-Json
    $jsonObject.req_headers = $req_headers
    try {
        $original_Headers = $jsonObject.original_headers | ConvertFrom-Json -ErrorAction Stop
        $jsonObject.original_Headers = $original_Headers
    }
    catch {
        Write-Warning "Original_Headers not present in this blob"
    }
    # Recursive function to remove invalid properties
    function Remove-InvalidProps {
        param (
            [Parameter(Mandatory = $true)]
            [PSCustomObject]$Object
        )
        # Get the keys to remove
        $keysToRemove = $Object.PSObject.Properties.Name | Where-Object { $_ -match '^_' -or $_ -match '^@' -or $_ -eq 'time' -or $_ -eq 'content-type' }
        # Remove the keys
        foreach ($key in $keysToRemove) {
            $Object.PSObject.Properties.Remove($key)
        }
        # Recursively process nested objects
        foreach ($key in $Object.PSObject.Properties.Name) {
            if ($Object.$key -is [PSCustomObject]) {
                Remove-InvalidProps -Object $Object.$key
            }
        }
    }
    # Call the recursive function
    Remove-InvalidProps -Object $jsonObject
    # Convert the cleaned object back to a JSON string
    return $jsonObject | ConvertTo-Json -Depth 2 -Compress
}
# Input Sanitizer
Function Format-DirtyJson ([string]$jsonString) {
    $jsonString = $jsonString -replace '[/&<>]', {
        switch ($args) {
            "/" { "&#x2F;" }
            "&" { "&amp;" }
            "<" { "&lt;" }
            ">" { "&gt;" }
            #'"' { '\"' }
        }
    }
    # $jsonString = $jsonString -replace "[']", {
    # switch ($args) {
    # "'" { "&#x27;" }
    # }
    # }
    return $jsonString
}
# # Output Sanitizer
# Function Format-DirtyKustoJson ([string]$jsonString) {
#     # $jsonString = $jsonString -replace '[\[\]/&<>]', {
#     #     switch ($args) {
#     #         "/" { "\/" }
#     #         "&" { "\&" }
#     #         "<" { "\<" }
#     #         ">" { "\>" }
#     #         "/" { "\/" }
#     #         #'"' { '\"' }
#     #     }
#     # }
#     $jsonString = $jsonString -replace "[\\]", {
#     switch ($args) {
#     "\" { "\\\\" }
#     }
#     }
#     return $jsonString
# }
# Input Expander
Function Expand-JsonGzip([string]$logpath) {
    # Define the path to the decompressed .json file
    $jsonFilePath = [System.IO.Path]::ChangeExtension($logpath, ".json")
    # Open the .gzip file for reading
    $gzipStream = [System.IO.File]::OpenRead($logpath)
    # Create a GzipStream object for decompression
    $decompressStream = New-Object System.IO.Compression.GzipStream($gzipStream, [System.IO.Compression.CompressionMode]::Decompress)
    # Create a FileStream object to write the decompressed content to a .json file
    $jsonStream = [System.IO.File]::Create($jsonFilePath)
    # Copy the decompressed content to the .json file
    $decompressStream.CopyTo($jsonStream)
    # Close the streams
    $decompressStream.Close()
    $jsonStream.Close()
    $gzipStream.Close()
    # Read the JSON content from the decompressed .json file
    $jsonContent = Get-Content -Path $jsonFilePath -Raw
    $encodedJson = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($jsonContent))
    # Remove the decompressed .json file
    Remove-Item -Path $jsonFilePath
    # Output the JSON content
    return $encodedJson
}
##### Execution
# Get/Set Identity for authenticated App Insights trace filtering. May not be necessary if expected env vars are set?
# $appInsightsID = Set-AppInsightsID
Write-LogHeader
# Validate output destination is expected (old OMS/LA API)
if ($LAURI.Trim() -notmatch 'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$') {
    Write-Error -Message ("Storage Account Blobs Ingestion: Invalid Log Analytics Uri." + $LAURI) -ErrorAction Stop
    Exit
}
# LogFile get (check/skip last, concurrency, etc)
if (($BlobType -ne 'BlockBlob' -or $BlobCType -ne 'application/x-ndjson' -or $BlobName -notmatch "\.log$") -and
    ($BlobType -ne 'BlockBlob' -or $BlobCType -ne 'application/x-ndjson' -or $BlobEncoding -ne 'gzip' -or $BlobName -notmatch "\.gzip$"))
{ $skipfile = 1; Write-Warning ("Blob does not match expected file type: " + $BlobType + "  " +  $BlobCType) }
else {
    try {
        Get-AzStorageBlobContent -Context $AzureStorage -Container $ContainerName -Blob $BlobPath -Destination $logPath -Force
        Write-Host "Blob content downloaded to $logPath"
    } catch {
        $BlobGetResp = $_.Exception.Message
        Write-Error ("Get Blob Status Code: " + $BlobGetResp + " " + $_.Exception.Type + " " + $_.Exception.ScriptStackTrace)
        Write-Error ("Get Blob Status Description:" + $_.Exception.CategoryInfo)
        $skipfile = 1
    }
}
# LogFile read/validate/process
if ($skipfile -eq 1){<#NOOP#>}
elseif ( !(Test-Path $logPath) -or $(Get-Content $logPath).length -eq 0 <#-or $blobContent -ne $(Get-Content $logPath)#>){
    <##TODO could inject a retry getblob here#>$skipfile = 1; Write-Error "Blob write to local cache went corrupt, empty, or missing."
}else {
    # LogFile read (switch for gzip/plaintext json)
    if ($BlobName -like "*gzip") {
        $logsFromFile = Expand-JsonGzip $logPath -Verbose;
    } else {
        $logsFromFile = Get-Content -Path $logPath -Raw
        $UTF8fromFile = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($logsFromFile))
    }
    $cleanedUnsafeJson = Format-DirtyJson $UTF8fromFile
    $validJson = $cleanedUnsafeJson | ConvertFrom-Json
    if (!$validJson){$skipfile =1;Write-Error "Contents of $logfile not valid json"}else{
        $renamedJsonPrimative = Build-ChaffedSortedJsonProps -rawJson $cleanedUnsafeJson
        # For use when log source only has prop values, no names:
        # $json = Convert-LogLineToJson($log)
        # $compressedJson = $renamedJsonPrimative|ConvertTo-Json -depth 2 -compress
        Write-Host ("Updated Json Props to be dispatched`n`n" + $renamedJsonPrimative + "`n")
        try {
        $LApostResult = Submit-ChunkLAdata -Corejson $renamedJsonPrimative -CustomLogName $LATableName
            Write-Host ("Compressed LA Post Result: " + $LApostResult)
        }catch {
            $LApostResult = Submit-ChunkLAdata -Corejson $renamedJsonPrimative -CustomLogName $LATableName
            Write-Warning ("Uncompressed LA Post Result: " + $LApostResult)
        }

        #TODO: Create chunking wrapper for LI API
        # For use if receiver is tolerant, which LI is very much not:
        # $kustoCompliantJson = Remove-InvalidProperties -jsonString $cleanedUnsafeJson
        # Don't rewrite native functions:
        # $escapedJson = Format-DirtyKustoJson $kustoCompliantJson
        $LIpostResult = Submit-LogIngestion -DCE $DCE -DCEEntAppId $DCEEntAppId -DCEEntAppRegKey $DCEEntAppRegKey `
        -tenantId $tenantId -Body $renamedJsonPrimative
        if ($LIpostResult -ne 200){
            Write-Host ("############################# LI-DCR/E POST Result: " + $LIpostResult)
        }else {
            Write-Warning ("########################## LI-DCR/E POST Result: " + $LIpostResult)
        }
    }
}
# LogFile/Blob/QueueMessage Cleanup
if ($LApostResult -eq 200 -or $LIpostResult -eq 200 <#-or $skipfile -eq 1#>) {
    # Skip deletion of empty/irrelevant blobs
    if (!$skipfile) {
        if ($LApostResult -eq 200) {Write-Host ("Storage Account Blobs ingested into Azure Monitoring API to Workspace Table $LATableName")}
        if ($LIpostResult -eq 200) { Write-Host ("Storage Account Blobs ingested into Azure Log Ingestion API to Workspace Table $DCETable") }
        Remove-AzStorageBlob -Context $AzureStorage -Container $ContainerName -Blob $BlobPath
        Remove-Item $logPath
    }else{
        # We polled a queue message about a blob that was missing or invalid. Could just nix queue message to prevent retry.
        $queueDelResponse = Remove-AzStorageQueueMessage -StorageAccountName $StorageAccountName -queueName $StgQueueName `
        -messageId $QueueID -popReceipt $QueuePOP -connectionString $AzureWebJobsStorage
        Write-Host ("Queue Message Deletion Status: " + $queueDelResponse)
    }
}
Write-LogFooter
# Cleanup env
[System.GC]::collect() #cleanup memory
[System.GC]::GetTotalMemory($true) | out-null #Force full garbage collection
# >>EOF