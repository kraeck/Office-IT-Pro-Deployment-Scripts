﻿[CmdletBinding()]
Param(
    [Parameter()]
    [bool] $WaitForUpdateToFinish = $true,

    [Parameter()]
    [bool] $EnableUpdateAnywhere = $true
)

Function Write-Log {
 
    PARAM
	(
         [String]$Message,
         [String]$Path = $LogFilePath,
         [int]$severity,
         [string]$component
	)
 
    try {
        # Get Windows Folder Path
        $windowsDirectory = [Environment]::GetFolderPath("Windows")

        # Build log folder
        $logFolderPath = "$windowsDirectory\CCM\logs"

         # Set log file name
        $LogFileName = "Office365UpdateAnywhere.log"

        # Build log path
        $LogFilePath = Join-Path $logFolderPath $LogFileName

        # Create log file
        If (!($(Test-Path $LogFilePath -PathType Leaf)))
        {
            $null = New-Item -Path $LogFilePath -ItemType File -ErrorAction SilentlyContinue
        }

	    $TimeZoneBias = Get-WmiObject -Query "Select Bias from Win32_TimeZone"
        $Date= Get-Date -Format "HH:mm:ss.fff"
        $Date2= Get-Date -Format "MM-dd-yyyy"
        $type=1
 
        if ($Path) {
           "<![LOG[$Message]LOG]!><time=$([char]34)$date$($TimeZoneBias.bias)$([char]34) date=$([char]34)$date2$([char]34) component=$([char]34)$component$([char]34) context=$([char]34)$([char]34) type=$([char]34)$severity$([char]34) thread=$([char]34)$([char]34) file=$([char]34)$([char]34)>"| Out-File -FilePath $Path -Append -NoClobber -Encoding default
        }
    } catch {

    }
}

Function Set-Reg {
	PARAM
	(
        [String]$hive,
        [String]$keyPath,
	    [String]$valueName,
	    [String]$value,
        [String]$Type
    )

    Try
    {
        $null = New-ItemProperty -Path "$($hive):\$($keyPath)" -Name "$($valueName)" -Value "$($value)" -PropertyType $Type -Force -ErrorAction Stop
    }
    Catch
    {
        Write-Log -Message $_.Exception.Message -severity 3 -component $LogFileName
    }
}

Function StartProcess {
	Param
	(
		[String]$execFilePath,
        [String]$execParams
	)

    Try
    {
        $execStatement = [System.Diagnostics.Process]::Start( $execFilePath, $execParams ) 
        $execStatement.WaitForExit()
    }
    Catch
    {
        Write-Log -Message $_.Exception.Message -severity 1 -component "Office 365 Update Anywhere"
    }
}

Function Get-OfficeCDNUrl() {
    $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    if (!($CDNBaseUrl)) {
       $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    }
    if (!($CDNBaseUrl)) {
        Push-Location
        $path15 = 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\ProductReleaseIDs\Active\stream'
        $path16 = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs\Active\stream'
        if (Test-Path -Path $path16) { Set-Location $path16 }
        if (Test-Path -Path $path15) { Set-Location $path15 }

        $items = Get-Item . | Select-Object -ExpandProperty property
        $properties = $items | ForEach-Object {
           New-Object psobject -Property @{"property"=$_; "Value" = (Get-ItemProperty -Path . -Name $_).$_}
        }

        $value = $properties | Select Value
        $firstItem = $value[0]
        [string] $cdnPath = $firstItem.Value

        $CDNBaseUrl = Select-String -InputObject $cdnPath -Pattern "http://officecdn.microsoft.com/.*/.{8}-.{4}-.{4}-.{4}-.{12}" -AllMatches | % { $_.Matches } | % { $_.Value }
        Pop-Location
    }
    return $CDNBaseUrl
}

Function Get-OfficeCTRRegPath() {
    $path15 = 'SOFTWARE\Microsoft\Office\15.0\ClickToRun'
    $path16 = 'SOFTWARE\Microsoft\Office\ClickToRun'

    if (Test-Path "HKLM:\$path15") {
      return $path15
    } else {
      if (Test-Path "HKLM:\$path16") {
         return $path16
      }
    }
}

Function Test-UpdateSource() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $UpdateSource = $NULL
    )

  	$uri = [System.Uri]$UpdateSource
	$sourceIsAlive = Test-Connection -Count 1 -computername $uri.Host -Quiet
    return $sourceIsAlive
}

Function Update-Office365Anywhere() {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [bool] $WaitForUpdateToFinish = $true,

        [Parameter()]
        [bool] $EnableUpdateAnywhere = $true,

        [Parameter()]
        [bool] $ForceAppShutdown = $false,

        [Parameter()]
        [bool] $UpdatePromptUser = $false,

        [Parameter()]
        [bool] $DisplayLevel = $false
    )

    $mainRegPath = Get-OfficeCTRRegPath
    $configRegPath = $mainRegPath + "\Configuration"

    $currentUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateUrl -ErrorAction SilentlyContinue).UpdateUrl
    $saveUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name SaveUpdateUrl -ErrorAction SilentlyContinue).SaveUpdateUrl
    $clientFolder = (Get-ItemProperty HKLM:\$configRegPath -Name ClientFolder -ErrorAction SilentlyContinue).ClientFolder

    $officeUpdateCDN = Get-OfficeCDNUrl

    $officeCDN = "http://officecdn.microsoft.com"
    $oc2rcFilePath = Join-Path $clientFolder "\OfficeC2RClient.exe"

    $oc2rcParams = "/update user"
    if ($ForceAppShutdown) {
      $oc2rcParams += " forceappshutdown=true"
    } else {
      $oc2rcParams += " forceappshutdown=false"
    }
    if ($UpdatePromptUser) {
      $oc2rcParams += " updatepromptuser=true"
    } else {
      $oc2rcParams += " updatepromptuser=false"
    }
    if ($DisplayLevel) {
      $oc2rcParams += " displaylevel=true"
    } else {
      $oc2rcParams += " displaylevel=false"
    }
    
    $UpdateSource = "http"
    if ($currentUpdateSource) {
        If ($currentUpdateSource.StartsWith("\\",1)) {
          $UpdateSource = "UNC"
        }
    }

    if ($EnableUpdateAnywhere) {
        if ($currentUpdateSource) {
            [bool]$isAlive = $false
            if ($currentUpdateSource.ToLower() -eq $officeUpdateCDN.ToLower() -and ($saveUpdateSource)) {
                if ($currentUpdateSource -ne $saveUpdateSource) {
	                $isAlive = Test-UpdateSource -UpdateSource $saveUpdateSource
                    if ($isAlive) {
                       Write-Log -Message "Restoring Saved Update Source $saveUpdateSource" -severity 1 -component "Office 365 Update Anywhere"
                       Set-Reg -Hive "HKLM" -keyPath $officeRegPath -ValueName "UpdateUrl" -Value $saveUpdateSource -Type String
                    }
                }
            }
        }

        if (!($currentUpdateSource)) {
           if ($officeUpdateCDN) {
               Write-Log -Message "No Update source is set so defaulting to Office CDN" -severity 1 -component "Office 365 Update Anywhere"
               Set-Reg -Hive "HKLM" -keyPath $officeRegPath -ValueName "UpdateUrl" -Value $officeUpdateCDN -Type String
               $currentUpdateSource = $officeUpdateCDN
           }
        }

        if (!$isAlive) {
            $isAlive = Test-UpdateSource -UpdateSource $currentUpdateSource
            if (!($isAlive)) {
                if ($currentUpdateSource.ToLower() -ne $officeUpdateCDN.ToLower()) {
                  Set-Reg -Hive "HKLM" -keyPath $officeRegPath -ValueName "SaveUpdateUrl" -Value $currentUpdateSource -Type String
                }

               Write-Log -Message "Unable to use $currentUpdateSource. Will now use $officeUpdateCDN" -severity 1 -component "Office 365 Update Anywhere"
               Set-Reg -Hive "HKLM" -keyPath $officeRegPath -ValueName "UpdateUrl" -Value $officeUpdateCDN -Type String
            }
        }
    } else {
      $isAlive = Test-UpdateSource -UpdateSource $currentUpdateSource
    }

    if ($isAlive) {
       Write-Host "Starting Update process"
       Write-Log -Message "Will now execute $oc2rcFilePath $oc2rcParams" -severity 1 -component "Office 365 Update Anywhere"
       StartProcess -execFilePath $oc2rcFilePath -execParams $oc2rcParams

       if ($WaitForUpdateToFinish) {
            Wait-ForOfficeCTRUpadate
       }
    } else {
       $currentUpdateSource = (Get-ItemProperty HKLM:\$officeRegPath -Name UpdateUrl -ErrorAction SilentlyContinue).UpdateUrl
       Write-Host "Update Source '$currentUpdateSource' Unavailable"
       Write-Log -Message "Update Source '$currentUpdateSource' Unavailable" -severity 1 -component "Office 365 Update Anywhere"
    }
}

Function formatTimeItem() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $TimeItem = ""
    )

    [string]$returnItem = $TimeItem
    if ($TimeItem.Length -eq 1) {
       $returnItem = "0" + $TimeItem
    }
    return $returnItem
}

Function getOperationTime() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [DateTime] $OperationStart
    )

    $operationTime = ""

    $dateDiff = NEW-TIMESPAN –Start $OperationStart –End (GET-DATE)
    $strHours = formatTimeItem -TimeItem $dateDiff.Hours.ToString() 
    $strMinutes = formatTimeItem -TimeItem $dateDiff.Minutes.ToString() 
    $strSeconds = formatTimeItem -TimeItem $dateDiff.Seconds.ToString() 

    if ($dateDiff.Days -gt 0) {
        $operationTime += "Days: " + $dateDiff.Days.ToString() + ":"  + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Hours -gt 0 -and $dateDiff.Days -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Hours: " + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Minutes -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Minutes: " + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Seconds -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0 -and $dateDiff.Minutes -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Seconds: " + $strSeconds
    }

    return $operationTime
}

Function Wait-ForOfficeCTRUpadate() {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [int] $TimeOutInMinutes = 120
    )

    begin {
        $HKLM = [UInt32] "0x80000002"
        $HKCR = [UInt32] "0x80000000"
    }

    process {
       Write-Host "Waiting for Update process to Complete..."

       [datetime]$operationStart = Get-Date
       [datetime]$totalOperationStart = Get-Date

       Start-Sleep -Seconds 10

       $mainRegPath = Get-OfficeCTRRegPath
       $scenarioPath = $mainRegPath + "\scenario"

       $regProv = Get-Wmiobject -list "StdRegProv" -namespace root\default -ErrorAction Stop

       [DateTime]$startTime = Get-Date

       [string]$executingScenario = ""
       $failure = $false
       $cancelled = $false
       $updateRunning=$false
       [string[]]$trackProgress = @()
       [string[]]$trackComplete = @()
       [int]$noScenarioCount = 0

       do {
           $allComplete = $true
           $executingScenario = $regProv.GetStringValue($HKLM, $mainRegPath, "ExecutingScenario").sValue
           
           $scenarioKeys = $regProv.EnumKey($HKLM, $scenarioPath)
           foreach ($scenarioKey in $scenarioKeys.sNames) {
              if (!($executingScenario)) { continue }
              if ($scenarioKey.ToLower() -eq $executingScenario.ToLower()) {
                $taskKeyPath = Join-Path $scenarioPath "$scenarioKey\TasksState"
                $taskValues = $regProv.EnumValues($HKLM, $taskKeyPath).sNames

                foreach ($taskValue in $taskValues) {
                    [string]$status = $regProv.GetStringValue($HKLM, $taskKeyPath, $taskValue).sValue
                    $operation = $taskValue.Split(':')[0]
                    $keyValue = $taskValue
                   
                    if ($status.ToUpper() -eq "TASKSTATE_FAILED") {
                        $failure = $true
                    }

                    if ($status.ToUpper() -eq "TASKSTATE_CANCELLED") {
                        $cancelled = $true
                    }

                    if (($status.ToUpper() -eq "TASKSTATE_COMPLETED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_CANCELLED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_FAILED")) {
                        if ($trackProgress.Contains($keyValue) -and !$trackComplete.Contains($keyValue)) {
                            $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                            #Write-Host $displayValue
                            $trackComplete += $keyValue 

                            $statusName = $status.Split('_')[1];

                            if ($operation.ToUpper().Contains("DOWNLOAD") -or `
                                $operation.ToUpper().Contains("APPLY")) {

                                $operationTime = getOperationTime -OperationStart $operationStart

                                $displayText = $statusName + "`t" + $operationTime

                                Write-Host $displayText
                            }
                        }
                    } else {
                        $allComplete = $false
                        $updateRunning=$true


                        if (!$trackProgress.Contains($keyValue)) {
                             $trackProgress += $keyValue 
                             $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

                             $operationStart = Get-Date

                             if ($operation.ToUpper().Contains("DOWNLOAD")) {
                                Write-Host "Downloading Update: " -NoNewline
                             }

                             if ($operation.ToUpper().Contains("APPLY")) {
                                Write-Host "Applying Update: " -NoNewline
                             }

                             if ($operation.ToUpper().Contains("FINALIZE")) {
                                Write-Host "Finalizing Update: " -NoNewline
                             }

                             #Write-Host $displayValue
                        }
                    }
                }
              }
           }

           if ($allComplete) {
              break;
           }

           if ($startTime -lt (Get-Date).AddHours(-$TimeOutInMinutes)) {
              throw "Waiting for Update Timed-Out"
              break;
           }

           Start-Sleep -Seconds 5
       } while($true -eq $true) 

       $operationTime = getOperationTime -OperationStart $operationStart

       $displayValue = ""
       if ($cancelled) {
         $displayValue = "CANCELLED`t" + $operationTime
       } else {
         if ($failure) {
            $displayValue = "FAILED`t" + $operationTime
         } else {
            $displayValue = "COMPLETED`t" + $operationTime
         }
       }

       Write-Host $displayValue

       $totalOperationTime = getOperationTime -OperationStart $totalOperationStart

       if ($updateRunning) {
          if ($failure) {
            Write-Host "Update Failed"
          } else {
            Write-Host "Update Completed - Total Time: $totalOperationTime"
          }
       } else {
          Write-Host "Update Not Running"
       } 
    }
}

Update-Office365Anywhere -WaitForUpdateToFinish $WaitForUpdateToFinish -EnableUpdateAnywhere $EnableUpdateAnywhere


