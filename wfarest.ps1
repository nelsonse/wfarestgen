Function Invoke-WebResponse {
	param(
		[Parameter(Mandatory = $true)] $request
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	
	Try {
		$response = $request.GetResponse()
	} Catch [System.Net.WebException] {
		$ex = $_.Exception.Response.StatusCode
		$response.Close()
		Throw "Workflow not found - Exception from server: $ex"
	} Catch [System.Exception] {
		$response.Close()
		Throw "Some other random error..$($_.Exception)"
	}
	
	$readStream = $response.GetResponseStream()
	$reader = New-Object System.IO.StreamReader($readStream)
	
	Try {
		$output = [xml] $reader.readtoend()
	} Catch {
		Throw "Exception reading stream from server.  Exception: $($_.Exception)"
	} Finally {
		$response.Close()
		$reader.Close()
	}
	return $output
}

Function Invoke-WFAGet {
	param(
		[Parameter(Mandatory = $true)] $url,
		[Parameter(Mandatory = $true)] $cred
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	$request = [System.Net.HttpWebRequest]::Create($url)
	$request.Credentials = $cred
	
	return $(Invoke-WebResponse -request $request)
}


Function Invoke-WFAPut {
	param(
		[Parameter(Mandatory=$true)] $url,
		[Parameter(Mandatory=$true)] $cred,
		[Parameter(Mandatory=$true)] [xml] $xml
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	$request = [System.Net.HttpWebRequest]::Create($url)
	$request.Credentials = $cred
	$request.Method = "POST"
	$request.ProtocolVersion = "1.0"
	$request.ContentType = "application/xml"

	# Create the input stream to the REST API
	$requestInputStream = $request.GetRequestStream()

	# Create a stream writer to write the XML
	$writer = New-Object System.IO.StreamWriter($requestInputStream)
	$writer.AutoFlush = $true

	# Write the XML
	Try {
		$writer.Write($($xml.OuterXml))
	} Catch [System.IO.IOException] {
		Throw "Cannot write to stream. Exception $($_.Exception)"
	} Catch [System.Exception] {
		Throw "Some other weird error caught...$($_.Exception)"
	} Finally {
		$writer.Close()
	}
	return $(Invoke-WebResponse -request $request)
}

Function Get-WFALinks {
	param(
		[Parameter(Mandatory = $true)] $linkList,
		[Parameter(Mandatory = $true)] $linkToFind
	)
	<#
	Find the link requested.  The documentation does not appear to 
	be reliable in this manner as the order is not correctly documented
	in the original REST document on the communities site.  So in order
	to avoid executing the wrong link by having a hard reference, we build
	a function to search for the link in the list.
	#>
	for($x = 0 ; $x -lt $linkList.Count; $x++) {
		if($($linkList[$x]).rel -match $linkToFind) {
			$href = $($linkList[$x]).href
			break
		}
	}
	return $href
}

Function Get-InArray {
	param(
		[Parameter(Mandatory=$true)] $find,
		[Parameter(Mandatory=$true)] [array] $inA
	)
	<#
	Stupid function to fix the lack of the -in operator in 
	PoSH 2.0
	#>
	foreach ($item in $inA) {
		if($find -match $item -or $find -eq $item) { return $true }
	}
	return $false
}

Function Get-WFAJobStatus {
	param(
		[Parameter(Mandatory=$true)] $status
	)
	$badStat = @("FAILED", "ABORTING", "CANCELED", "OBSOLETE")
	$okStat = @("PAUSED", "RUNNING", "PENDING", "SCHEDULED", "EXECUTING")
	$doneStat = "COMPLETED"
	if($(Get-InArray -find $status -inA $okStat)) { 
		return "OK"
	} elseif ($status -match $doneStat) {
		return "DONE"
	} elseif ($(Get-InArray -find $status -inA $badStat)) {
		return "FAILED"
	} else {
		return "UNKNOWN"
	}
}

# Setup the core for the script.  Dont change the URL unless you are remotely executing
# or have a non-default port.
$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$sleepTime = 5
$wfaHost = "cyberman"
$url = "http://" + $wfaHost + "/rest/workflows"

# This is replaced by the WFA credential request. Simply for testing.
$user = "NELSON-NET\stnel"
$ptpw = "sp1Tfir3"
$pw = ConvertTo-SecureString -String $ptpw -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($user, $pw)

# Get your workflow inputs here...these will be parameters in the WFA script
$workflowToExecute = "Create-Volume (Schwab)"
$cluster = "sbn-clus2"
$vserver = "vserver821"
$volname = "sntest4"
$aggr = "aggr_sbn_clus_02_01"
$volComment = "testvolume"
# size in GB!
$size = 1

# Build the input XML.
$xmlOut = [xml] @"
<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>
	<workflowInput>
		<userInputValues>
			<userInputEntry key = "clusterName" value = "$cluster"/>
			<userInputEntry key = "vserver" value = "$vserver"/>
			<userInputEntry key = "aggr" value = "$aggr"/>
			<userInputEntry key = "volName" value = "$volname"/>
			<userInputEntry key = "volComment" value = "$volComment"/>
			<userInputEntry key = "size" value = "$size"/>
		</userInputValues>
	</workflowInput>
"@

# Build the URI to test if this workflow actually exists and to get the 'execute' href
$newUrl = $url + "?name=" + $([System.Web.HttpUtility]::UrlPathEncode($workflowToExecute))

# Get the workflow information
$workflow = $(Invoke-WFAGet -url $newUrl -cred $cred).collection.workflow

# Derive the href for "execute"
$href = Get-WFALinks -linkList $($workflow.link) -linkToFind "execute"

# Invoke the PUT with the execute href and the XML
$output = Invoke-WFAPut -url $href -cred $cred -xml $xmlOut
$status = Get-WFAJobStatus -status $($output.job.jobStatus.jobStatus)

if($status -match "OK" -or $status -match "DONE") {
	# Get the href so we can get status of the job
	$href = Get-WFALinks -linkList $($output.job.link) -linkToFind "self"
	
	while($status -match "OK") {
		$status = $(Invoke-WFAGet -url $href -cred $cred).job.jobStatus.jobStatus
		Write-output "Current Status: $status"
		sleep $sleepTime
	}
	
	switch($status) {
		"DONE" {
			Write-Output "Job complete"
			exit 0
		}
		"FAILED" {
			Write-Output "Job Failed"
			exit 1
		}
		"UNKNOWN" {
			Write-Output "Indeterminate status.  Status returned was $status"
			exit 2
		}
	}
} else {
	Write-output "Job start failed!  Status was: $status"
	exit 3
}