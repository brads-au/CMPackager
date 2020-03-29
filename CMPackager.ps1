﻿<#	
	.NOTES
	===========================================================================
	 Created on:   	1/9/2018 11:34 AM
	 Last Updated:  12/31/2019
	 Author:		Andrew Jimenez (asjimene) - https://github.com/asjimene/
	 Filename:     	CMPackager.ps1
	===========================================================================
	.DESCRIPTION
		Packages Applications for ConfigMgr using XML Based Recipe Files

	Uses Scripts and Functions Sourced from the Following:
		Copy-CMDeploymentTypeRule - https://janikvonrotz.ch/2017/10/20/configuration-manager-configure-requirement-rules-for-deployment-types-with-powershell/
		Get-ExtensionAttribute - Jaap Brasser - http://www.jaapbrasser.com
		Get-MSIInfo - Nickolaj Andersen - http://www.scconfigmgr.com/2014/08/22/how-to-get-msi-file-information-with-powershell/
	
	7-Zip Application is Redistributed for Ease of Use:
		7-Zip Binary - Igor Pavlov - https://www.7-zip.org/
#>

[CmdletBinding()]
param (
	[switch]$Setup = $false
)
DynamicParam {  
	$ParamAttrib = New-Object System.Management.Automation.ParameterAttribute
	$ParamAttrib.Mandatory = $false
	$ParamAttrib.ParameterSetName = '__AllParameterSets'
	$AttribColl = New-Object  System.Collections.ObjectModel.Collection[System.Attribute]
	$AttribColl.Add($ParamAttrib)
	$configurationFileNames = Get-ChildItem -Path "$PSScriptRoot\Recipes" | Select-Object -ExpandProperty Name
	$AttribColl.Add((New-Object System.Management.Automation.ValidateSetAttribute($configurationFileNames)))
	$RuntimeParam = New-Object System.Management.Automation.RuntimeDefinedParameter('SingleRecipe', [string], $AttribColl)
	$RuntimeParamDic = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
	$RuntimeParamDic.Add('SingleRecipe', $RuntimeParam)
	return  $RuntimeParamDic
}
process {

	$Global:ScriptVersion = "20.02.23.0"

	$Global:ScriptRoot = $PSScriptRoot

	if (-not (Test-Path "$ScriptRoot\CMPackager.prefs" -ErrorAction SilentlyContinue)) {
		$Setup = $true
	}
	## Global Variables (Only load if not setup)
	# Import the Prefs file
	if (-not ($Setup)) {
		[xml]$PackagerPrefs = Get-Content $ScriptRoot\CMPackager.prefs

		# Packager Vars
		$Global:TempDir = $PackagerPrefs.PackagerPrefs.TempDir
		$Global:LogPath = $PackagerPrefs.PackagerPrefs.LogPath
		$Global:MaxLogSize = 1000kb

		# Package Location Vars
		$Global:ContentLocationRoot = $PackagerPrefs.PackagerPrefs.ContentLocationRoot
		$Global:IconRepo = $PackagerPrefs.PackagerPrefs.IconRepo

		# CM Vars
		$Global:CMSite = $PackagerPrefs.PackagerPrefs.CMSite
		$Global:SiteCode = ($Global:CMSite).Replace(':', '')
		$Global:SiteServer = $PackagerPrefs.PackagerPrefs.SiteServer
		$Global:RequirementsTemplateAppName = $PackagerPrefs.PackagerPrefs.RequirementsTemplateAppName
		$Global:PreferredDistributionLoc = $PackagerPrefs.PackagerPrefs.PreferredDistributionLoc
		$Global:PreferredDeployCollection = $PackagerPrefs.PackagerPrefs.PreferredDeployCollection
		$Global:NoVersionInSWCenter = [System.Convert]::ToBoolean($PackagerPrefs.PackagerPrefs.NoVersionInSWCenter)


		# Email Vars
		[string[]]$Global:EmailTo = [string[]]$PackagerPrefs.PackagerPrefs.EmailTo
		$Global:EmailFrom = $PackagerPrefs.PackagerPrefs.EmailFrom
		$Global:EmailServer = $PackagerPrefs.PackagerPrefs.EmailServer
		$Global:SendEmailPreference = [System.Convert]::ToBoolean($PackagerPrefs.PackagerPrefs.SendEmailPreference)
		$Global:NotifyOnDownloadFailure = [System.Convert]::ToBoolean($PackagerPrefs.PackagerPrefs.NotifyOnDownloadFailure)

		$Global:EmailSubject = "CMPackager Report - $(Get-Date -format d)"
		$Global:EmailBody = "New Application Updates Packaged on $(Get-Date -Format d)`n`n"

		#This gets switched to True if Applications are Packaged
		$Global:SendEmail = $false
		$Global:TemplateApplicationCreatedFlag = $false
	}

	$Global:ConfigMgrConnection = $false
	$Global:XMLtoDisplayHash = @{"TempDir" = "WPFtextBoxWorkingDir";
		"ContentLocationRoot"                 = "WPFtextBoxContentRoot";
		"IconRepo"                            = "WPFtextBoxIconRepository";
		"CMSite"                              = "WPFtextBoxSiteCode";
		"SiteServer"                          = "WPFtextBoxSiteServer";
		"NoVersionInSWCenter"                 = "WPFtoggleButtonNoDisplayAppVer";
		"EmailTo"                             = "WPFtextBoxEmailTo";
		"EmailFrom"                           = "WPFtextBoxEmailFrom";
		"EmailServer"                         = "WPFtextBoxEmailServer";
		"SendEmailPreference"                 = "WPFtoggleButtonSendEmail";
		"NotifyOnDownloadFailure"             = "WPFtoggleButtonNotifyOnFailure";
		"PreferredDistributionLoc"            = "WPFcomboBoxPreferredDistPoint";
		"PreferredDeployCollection"           = "WPFcomboBoxPreferredDeployColl"
	}
		 
	if (Test-Path "$PSScriptRoot\CMPackager.prefs" -ErrorAction SilentlyContinue) {
		$CMPackagerXML = [XML](Get-Content "$PSScriptRoot\CMPackager.prefs")
	}
	else {
		$CMPackagerXML = [XML](Get-Content "$PSScriptRoot\CMPackager.prefs.template")
	}

	$Global:OperatorsLookup = @{ And = 'And'; Or = 'Or'; Other = 'Other'; IsEquals = 'Equals'; NotEquals = 'Not equal to'; GreaterThan = 'Greater than'; LessThan = 'Less than'; Between = 'Between'; NotBetween = 'Not Between'; GreaterEquals = 'Greater than or equal to'; LessEquals = 'Less than or equal to'; BeginsWith = 'Begins with'; NotBeginsWith = 'Does not begin with'; EndsWith = 'Ends with'; NotEndsWith = 'Does not end with'; Contains = 'Contains'; NotContains = 'Does not contain'; AllOf = 'All of'; OneOf = 'OneOf'; NoneOf = 'NoneOf'; SetEquals = 'Set equals'; SubsetOf = 'Subset of'; ExcludesAll = 'Exludes all' }
	## Functions
	function Add-LogContent {
		param
		(
			[parameter(Mandatory = $false)]
			[switch]$Load,
			[parameter(Mandatory = $true)]
			$Content
		)
		if ($Load) {
			if ((Get-Item $LogPath -ErrorAction SilentlyContinue).length -gt $MaxLogSize) {
				Write-Output "$(Get-Date -Format G) - $Content" > $LogPath
			}
			else {
				Write-Output "$(Get-Date -Format G) - $Content" >> $LogPath
			}
		}
		else {
			Write-Output "$(Get-Date -Format G) - $Content" >> $LogPath
		}
	}

	function Get-ExtensionAttribute {
		<#
.Synopsis
Retrieves extension attributes from files or folder

.DESCRIPTION
Uses the dynamically generated parameter -ExtensionAttribute to select one or multiple extension attributes and display the attribute(s) along with the FullName attribute

.NOTES   
Name: Get-ExtensionAttribute.ps1
Author: Jaap Brasser
Version: 1.0
DateCreated: 2015-03-30
DateUpdated: 2015-03-30
Blog: http://www.jaapbrasser.com

.LINK
http://www.jaapbrasser.com

.PARAMETER FullName
The path to the file or folder of which the attributes should be retrieved. Can take input from pipeline and multiple values are accepted.

.PARAMETER ExtensionAttribute
Additional values to be loaded from the registry. Can contain a string or an array of string that will be attempted to retrieve from the registry for each program entry

.EXAMPLE   
. .\Get-ExtensionAttribute.ps1
    
Description 
-----------     
This command dot sources the script to ensure the Get-ExtensionAttribute function is available in your current PowerShell session

.EXAMPLE
Get-ExtensionAttribute -FullName C:\Music -ExtensionAttribute Size,Length,Bitrate

Description
-----------
Retrieves the Size,Length,Bitrate and FullName of the contents of the C:\Music folder, non recursively

.EXAMPLE
Get-ExtensionAttribute -FullName C:\Music\Song2.mp3,C:\Music\Song.mp3 -ExtensionAttribute Size,Length,Bitrate

Description
-----------
Retrieves the Size,Length,Bitrate and FullName of Song.mp3 and Song2.mp3 in the C:\Music folder

.EXAMPLE
Get-ChildItem -Recurse C:\Video | Get-ExtensionAttribute -ExtensionAttribute Size,Length,Bitrate,Totalbitrate

Description
-----------
Uses the Get-ChildItem cmdlet to provide input to the Get-ExtensionAttribute function and retrieves selected attributes for the C:\Videos folder recursively

.EXAMPLE
Get-ChildItem -Recurse C:\Music | Select-Object FullName,Length,@{Name = 'Bitrate' ; Expression = { Get-ExtensionAttribute -FullName $_.FullName -ExtensionAttribute Bitrate | Select-Object -ExpandProperty Bitrate } }

Description
-----------
Combines the output from Get-ChildItem with the Get-ExtensionAttribute function, selecting the FullName and Length properties from Get-ChildItem with the ExtensionAttribute Bitrate
#>
		[CmdletBinding()]
		Param (
			[Parameter(ValueFromPipeline = $true,
				ValueFromPipelineByPropertyName = $true,
				Position = 0)]
			[string[]]$FullName
		)
		DynamicParam {
			$Attributes = New-Object System.Management.Automation.ParameterAttribute
			$Attributes.ParameterSetName = "__AllParameterSets"
			$Attributes.Mandatory = $false
			$AttributeCollection = New-Object -Type System.Collections.ObjectModel.Collection[System.Attribute]
			$AttributeCollection.Add($Attributes)
			$Values = @($Com = (New-Object -ComObject Shell.Application).NameSpace('C:\'); 1 .. 400 | ForEach-Object { $com.GetDetailsOf($com.Items, $_) } | Where-Object { $_ } | ForEach-Object { $_ -replace '\s' })
			$AttributeValues = New-Object System.Management.Automation.ValidateSetAttribute($Values)
			$AttributeCollection.Add($AttributeValues)
			$DynParam1 = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("ExtensionAttribute", [string[]], $AttributeCollection)
			$ParamDictionary = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
			$ParamDictionary.Add("ExtensionAttribute", $DynParam1)
			$ParamDictionary
		}
	
		begin {
			$ShellObject = New-Object -ComObject Shell.Application
			$DefaultName = $ShellObject.NameSpace('C:\')
			$ExtList = 0 .. 400 | ForEach-Object {
				($DefaultName.GetDetailsOf($DefaultName.Items, $_)).ToUpper().Replace(' ', '')
			}
		}
	
		process {
			foreach ($Object in $FullName) {
				# Check if there is a fullname attribute, in case pipeline from Get-ChildItem is used
				if ($Object.FullName) {
					$Object = $Object.FullName
				}
			
				# Check if the path is a single file or a folder
				if (-not (Test-Path -Path $Object -PathType Container)) {
					$CurrentNameSpace = $ShellObject.NameSpace($(Split-Path -Path $Object))
					$CurrentNameSpace.Items() | Where-Object {
						$_.Path -eq $Object
					} | ForEach-Object {
						$HashProperties = @{
							FullName = $_.Path
						}
						foreach ($Attribute in $MyInvocation.BoundParameters.ExtensionAttribute) {
							$HashProperties.$($Attribute) = $CurrentNameSpace.GetDetailsOf($_, $($ExtList.IndexOf($Attribute.ToUpper())))
						}
						New-Object -TypeName PSCustomObject -Property $HashProperties
					}
				}
				elseif (-not $input) {
					$CurrentNameSpace = $ShellObject.NameSpace($Object)
					$CurrentNameSpace.Items() | ForEach-Object {
						$HashProperties = @{
							FullName = $_.Path
						}
						foreach ($Attribute in $MyInvocation.BoundParameters.ExtensionAttribute) {
							$HashProperties.$($Attribute) = $CurrentNameSpace.GetDetailsOf($_, $($ExtList.IndexOf($Attribute.ToUpper())))
						}
						New-Object -TypeName PSCustomObject -Property $HashProperties
					}
				}
			}
		}
	
		end {
			Remove-Variable -Force -Name DefaultName
			Remove-Variable -Force -Name CurrentNameSpace
			Remove-Variable -Force -Name ShellObject
		}
	}

	function Get-MSIInfo {
		param (
			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[System.IO.FileInfo]$Path,
			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[ValidateSet("ProductCode", "ProductVersion", "ProductName", "Manufacturer", "ProductLanguage", "FullVersion", "InstallPrerequisites")]
			[string]$Property
		)
	
		Process {
			try {
				# Read property from MSI database
				$WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
				$MSIDatabase = $WindowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $WindowsInstaller, @($Path.FullName, 0))
				$Query = "SELECT Value FROM Property WHERE Property = '$($Property)'"
				$View = $MSIDatabase.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $MSIDatabase, ($Query))
				$View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
				$Record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $View, $null)
				$Value = $Record.GetType().InvokeMember("StringData", "GetProperty", $null, $Record, 1)
			
				# Commit database and close view
				$MSIDatabase.GetType().InvokeMember("Commit", "InvokeMethod", $null, $MSIDatabase, $null)
				$View.GetType().InvokeMember("Close", "InvokeMethod", $null, $View, $null)
				$MSIDatabase = $null
				$View = $null
			
				# Return the value
				return $Value
			}
			catch {
				Write-Warning -Message $_.Exception.Message; break
			}
		}
		End {
			# Run garbage collection and release ComObject
			[System.Runtime.Interopservices.Marshal]::ReleaseComObject($WindowsInstaller) | Out-Null
			[System.GC]::Collect()
		}
	}

	function Invoke-VersionCheck {
		## Contact CM and determine if the Application Version is New
		[CmdletBinding()]
		param (
			[Parameter()]
			[String]
			$ApplciationName,
			[Parameter()]
			[String]
			$ApplciationSWVersion
		)

		Push-Location
		Set-Location $Global:CMSite
		If ((-not (Get-CMApplication -Name "$ApplicationName $ApplicationSWVersion" -Fast)) -and (-not ([System.String]::IsNullOrEmpty($ApplicationSWVersion)))) {
			$newApp = $true			
			Add-LogContent "$ApplicationSWVersion is a new Version"
		}
		Else {
			$newApp = $false
			Add-LogContent "$ApplicationSWVersion is not a new Version - Moving to next application"
		}
        
		# If SkipPackaging is specified, return that the app is up-to-date.
		if ($ApplicationSWVersion -eq "SkipPackaging") {
			$newApp = $false
		}

		Pop-Location
		Write-Output $newApp
	}

	Function Start-ApplicationDownload {
		Param (
			$Recipe
		)
		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		$newApp = $false

		ForEach ($Download In $Recipe.ApplicationDef.Downloads.ChildNodes) {
			## Set Variables
			$DownloadFileName = $Download.DownloadFileName
			$URL = $Download.URL
			$DownloadVersionCheck = $Download.DownloadVersionCheck
			$DownloadFile = "$TempDir\$DownloadFileName"
			$AppRepoFolder = $Download.AppRepoFolder
			$ExtraCopyFunctions = $Download.ExtraCopyFunctions

			## Run the prefetch script if it exists
			$PrefetchScript = $Download.PrefetchScript
			If (-not ([String]::IsNullOrEmpty($PrefetchScript))) {
				Invoke-Expression $PrefetchScript | Out-Null
			}

			if (-not ([System.String]::IsNullOrEmpty($Version))) {
				## Version Check after prefetch script (skip download if possible)
				## This was not working well. Will revisit later
				#$newApp = Invoke-VersionCheck -ApplciationName $ApplicationName -ApplciationSWVersion ([string]$Version)
				$newApp = $true
			}
			else {
				$newApp = $true
			}
			
			Add-LogContent "Version Check after prefetch script is $newapp"

			## Download the Application
			If ((-not ([String]::IsNullOrEmpty($URL))) -and ($newapp)) {
				Add-LogContent "Downloading $ApplicationName from $URL"
				$ProgressPreference = 'SilentlyContinue'
				$request = Invoke-WebRequest -Uri "$URL" -OutFile $DownloadFile -ErrorAction Ignore
				$request | Out-Null
				Add-LogContent "Completed Downloading $ApplicationName"
			}
			else {
				if (-not $newApp) {
					Add-LogContent "$Version was found in ConfigMgr, Skipping Download"
				}
				if ([String]::IsNullOrEmpty($URL)) {
					Add-LogContent "URL Not Specified, Skipping Download"
				}
			}

		
			## Run the Version Check Script and record the Version and FullVersion
			If (-not ([String]::IsNullOrEmpty($DownloadVersionCheck))) {
				Invoke-Expression $DownloadVersionCheck | Out-Null
			}
			$Download.Version = [string]$Version
			$Download.FullVersion = [string]$FullVersion
			$ApplicationSWVersion = $Download.Version
			Add-LogContent "Found Version $ApplicationSWVersion from Download FullVersion: $FullVersion"

			## Determine if the Download Failed or if an Application Version was not detected, and add the Failure to the email if the Flag is set
			if ((-not (Test-Path $DownloadFile)) -or ([System.String]::IsNullOrEmpty($ApplicationSWVersion))) {
				Add-LogContent "ERROR: Failed to Download or find the Version for $ApplicationName"
				if ($Global:NotifyOnDownloadFailure) {
					$Global:SendEmail = $true; $Global:SendEmail | Out-Null
					$Global:EmailBody += "   - Failed to Download: $ApplicationName`n"
				}
			}
		
			$newApp = Invoke-VersionCheck -ApplciationName $ApplicationName -ApplciationSWVersion $ApplicationSWVersion
		
			## Create the Application folders and copy the download if the Application is New
			If ($newapp) {
				## Create Application Share Folder
				If ([String]::IsNullOrEmpty($AppRepoFolder)) {
					$DestinationPath = "$Global:ContentLocationRoot\$ApplicationName\Packages\$Version"
					Add-LogContent "Destination Path set as $DestinationPath"
				}
				Else {
					$DestinationPath = "$Global:ContentLocationRoot\$ApplicationName\Packages\$Version\$AppRepoFolder"
					Add-LogContent "Destination Path set as $DestinationPath"
				}
				New-Item -ItemType Directory -Path $DestinationPath -Force
			
				## Copy to Download to Application Share
				Add-LogContent "Copying downloads to $DestinationPath"
				Copy-Item -Path $DownloadFile -Destination $DestinationPath -Force
			
				## Extra Copy Functions If Required
				If (-not ([String]::IsNullOrEmpty($ExtraCopyFunctions))) {
					Add-LogContent "Performing Extra Copy Functions"
					Invoke-Expression $ExtraCopyFunctions | Out-Null
				}
			}
		}
	
		## Return True if All Downloaded Applications were new Versions
		Return $NewApp
	}

	Function Invoke-ApplicationCreation {
		Param (
			$Recipe
		)
	
		## Set Variables
		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		$ApplicationPublisher = $Recipe.ApplicationDef.Application.Publisher
		$ApplicationDescription = $Recipe.ApplicationDef.Application.Description
		$ApplicationDocURL = $Recipe.ApplicationDef.Application.UserDocumentation
		$ApplicationIcon = "$Global:IconRepo\$($Recipe.ApplicationDef.Application.Icon)"
		$ApplicationFolderPath = $Recipe.ApplicationDef.Application.FolderPath
		if (-not (Test-Path $ApplicationIcon -ErrorAction SilentlyContinue)) {
			$ApplicationIcon = "$ScriptRoot\ExtraFiles\Icons\$($Recipe.ApplicationDef.Application.Icon)"
			if (-not (Test-Path $ApplicationIcon -ErrorAction SilentlyContinue)) {
				$ApplicationIcon = $null
			}
		}
		$ApplicationAutoInstall = [System.Convert]::ToBoolean($Recipe.ApplicationDef.Application.AutoInstall)
		$AppCreated = $true
	
		ForEach ($Download In ($Recipe.ApplicationDef.Downloads.Download)) {
			If (-not ([System.String]::IsNullOrEmpty($Download.Version))) {
				$ApplicationSWVersion = $Download.Version		
			}
		}
	
		## Create the Application
		Push-Location
		Set-Location $Global:CMSite
		Add-LogContent "Creating Application: $ApplicationName $ApplicationSWVersion"

		# Change the SW Center Display Name based on Setting
		if ($Global:NoVersionInSWCenter) {
			$ApplicationDisplayName = "$ApplicationName"
		}
		else {
			$ApplicationDisplayName = "$ApplicationName $ApplicationSWVersion"
		}

		Try {
			If (-not ([System.String]::IsNullOrEmpty($ApplicationIcon))) {
				Add-LogContent "Command: New-CMApplication -Name $ApplicationName $ApplicationSWVersion -Description $ApplicationDescription -Publisher $ApplicationPublisher -SoftwareVersion $ApplicationSWVersion -OptionalReference $ApplicationDocURL -AutoInstall $ApplicationAutoInstall -ReleaseDate (Get-Date) -LocalizedName $ApplicationDisplayName -LocalizedDescription $ApplicationDescription -UserDocumentation $ApplicationDocURL -IconLocationFile $ApplicationIcon"
				New-CMApplication -Name "$ApplicationName $ApplicationSWVersion" -Description "$ApplicationDescription" -Publisher "$ApplicationPublisher" -SoftwareVersion $ApplicationSWVersion -OptionalReference $ApplicationDocURL -AutoInstall $ApplicationAutoInstall -ReleaseDate (Get-Date) -LocalizedName "$ApplicationDisplayName" -LocalizedDescription "$ApplicationDescription" -UserDocumentation $ApplicationDocURL -IconLocationFile "$ApplicationIcon"
			}
			Else {
				Add-LogContent "Command: New-CMApplication -Name $ApplicationName $ApplicationSWVersion -Description $ApplicationDescription -Publisher $ApplicationPublisher -SoftwareVersion $ApplicationSWVersion -OptionalReference $ApplicationDocURL -AutoInstall $ApplicationAutoInstall -ReleaseDate (Get-Date) -LocalizedName $ApplicationDisplayName -LocalizedDescription $ApplicationDescription -UserDocumentation $ApplicationDocURL"
				New-CMApplication -Name "$ApplicationName $ApplicationSWVersion" -Description "$ApplicationDescription" -Publisher "$ApplicationPublisher" -SoftwareVersion $ApplicationSWVersion -OptionalReference $ApplicationDocURL -AutoInstall $ApplicationAutoInstall -ReleaseDate (Get-Date) -LocalizedName "$ApplicationDisplayName" -LocalizedDescription "$ApplicationDescription" -UserDocumentation $ApplicationDocURL
			}
		}
		Catch {
			$AppCreated = $false
			$ErrorMessage = $_.Exception.Message
			$FullyQualified = $_.FullyQualifiedErrorID
			Add-LogContent "ERROR: Application Creation Failed!"
			Add-LogContent "ERROR: $ErrorMessage"
			Add-LogContent "ERROR: $FullyQualified"
			Add-LogContent "ERROR: $($_.CategoryInfo.Category): $($_.CategoryInfo.Reason)"
		}

		# Move the Application to folder path if supplied
		Try {
			If (-not ([System.String]::IsNullOrEmpty($ApplicationFolderPath))) {
				Add-LogContent "Command: Move-CMObject -InputObject (Get-CMApplication -Name ""$ApplicationName $ApplicationSWVersion"") -FolderPath "".\Application\$ApplicationFolderPath"""
				Move-CMObject -InputObject (Get-CMApplication -Name "$ApplicationName $ApplicationSWVersion") -FolderPath ".\Application\$ApplicationFolderPath"
			}
		}
		Catch { 
			$AppCreated = $false
			$ErrorMessage = $_.Exception.Message
			$FullyQualified = $_.FullyQualifiedErrorID
			Add-LogContent "ERROR: Application Move Failed!"
			Add-LogContent "ERROR: $ErrorMessage"
			Add-LogContent "ERROR: $FullyQualified"
			Add-LogContent "ERROR: $($_.CategoryInfo.Category): $($_.CategoryInfo.Reason)"
		}

		## Send an Email if an Application was successfully Created and record the Application Name and Version for the Email
		If ($AppCreated) {
			$Global:SendEmail = $true; $Global:SendEmail | Out-Null
			$Global:EmailBody += "   - $ApplicationName $ApplicationSWVersion`n"
		}
		Pop-Location
	
		## Return True if the Application was Created Successfully
		Return $AppCreated
	}

	Function Add-DetectionMethodClause {
		Param (
			$DetectionMethod,
			$AppVersion,
			$AppFullVersion
		)
	
		$detMethodDetectionClauseType = $DetectionMethod.DetectionClauseType
		Add-LogContent "Adding Detection Method Clause Type $detMethodDetectionClauseType"
		Switch ($detMethodDetectionClauseType) {
			Directory {
				$detMethodCommand = "New-CMDetectionClauseDirectory"
				If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Name))) {
					$detMethodCommand += " -DirectoryName `'$($DetectionMethod.Name)`'"
				}
			}
			File {
				$detMethodCommand = "New-CMDetectionClauseFile"
				If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Name))) {
					$detMethodCommand += " -FileName `'$($DetectionMethod.Name)`'"
				}
			}
			RegistryKey {
				$detMethodCommand = "New-CMDetectionClauseRegistryKey"
			}
			RegistryKeyValue {
				$detMethodCommand = "New-CMDetectionClauseRegistryKeyValue"
			
			}
			WindowsInstaller {
				$detMethodCommand = "New-CMDetectionClauseWindowsInstaller"
			}
		}
		If (([System.Convert]::ToBoolean($DetectionMethod.Existence)) -and (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Existence)))) {
			$detMethodCommand += " -Existence"
		}
		If (([System.Convert]::ToBoolean($DetectionMethod.Is64Bit)) -and (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Is64Bit)))) {
			$detMethodCommand += " -Is64Bit"
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Path))) {
			$detMethodCommand += " -Path `'$($DetectionMethod.Path)`'"
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.PropertyType))) {
			$detMethodCommand += " -PropertyType $($DetectionMethod.PropertyType)"
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.ExpectedValue))) {
			$DetectionMethod.ExpectedValue = ($DetectionMethod.ExpectedValue).replace('$Version', $Version).replace('$FullVersion', $AppFullVersion)
			$detMethodCommand += " -ExpectedValue `"$($DetectionMethod.ExpectedValue)`""
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.ExpressionOperator))) {
			$detMethodCommand += " -ExpressionOperator $($DetectionMethod.ExpressionOperator)"
		}
		If (([System.Convert]::ToBoolean($DetectionMethod.Value)) -and (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Value)))) {
			$detMethodCommand += " -Value"
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.Hive))) {
			$detMethodCommand += " -Hive $($DetectionMethod.Hive)"
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.KeyName))) {
			$detMethodCommand += " -KeyName `"$($DetectionMethod.KeyName)`""
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.ValueName))) {
			$detMethodCommand += " -ValueName `"$($DetectionMethod.ValueName)`""
		}
		If (-not ([System.String]::IsNullOrEmpty($DetectionMethod.ProductCode))) {
			$detMethodCommand += " -ProductCode `"$($DetectionMethod.ProductCode)`""
		}
		Add-LogContent "$detMethodCommand"
	
		## Run the Detection Method Command as Created by the Logic Above
	
		Push-Location
		Set-Location $CMSite
		Try {
			$DepTypeDetectionMethod += Invoke-Expression $detMethodCommand
		}
		Catch {
			$ErrorMessage = $_.Exception.Message
			$FullyQualified = $_.Exeption.FullyQualifiedErrorID
			Add-LogContent "ERROR: Creating Detection Method Clause Failed!"
			Add-LogContent "ERROR: $ErrorMessage"
			Add-LogContent "ERROR: $FullyQualified"
		}
		Pop-Location
	
		## Return the Detection Method Variable
		Return $DepTypeDetectionMethod
	}

	Function Copy-CMDeploymentTypeRule {
		<#
	Function taken from https://janikvonrotz.ch/2017/10/20/configuration-manager-configure-requirement-rules-for-deployment-types-with-powershell/ and modified
 	
     #>
		Param (
			[System.String]$SourceApplicationName,
			[System.String]$DestApplicationName,
			[System.String]$DestDeploymentTypeName,
			[System.String]$RuleName
		)
		Push-Location
		Set-Location $CMSite
		$DestDeploymentTypeIndex = 0
 
		# get the applications
		$SourceApplication = Get-CMApplication -Name $SourceApplicationName | ConvertTo-CMApplication
		$DestApplication = Get-CMApplication -Name $DestApplicationName | ConvertTo-CMApplication
	
		# Get DestDeploymentTypeIndex by finding the Title
		$DestDeploymentTypeIndex = $DestApplication.DeploymentTypes.Title.IndexOf($DestDeploymentTypeName)
    
		$Available = ($SourceApplication.DeploymentTypes[0].Requirements).Name
		Add-LogContent "Available Requirements to chose from:`r`n $($Available -Join ', ')"
    
		# get requirement rules from source application
		$Requirements = $SourceApplication.DeploymentTypes[0].Requirements | Where-Object { (($_.Name).TrimStart().TrimEnd()) -eq (($RuleName).TrimStart().TrimEnd()) }
		if ([System.String]::IsNullOrEmpty($Requirements)) {
			Add-LogContent "No Requirement rule was an exact match for $RuleName"
			$Requirements = $SourceApplication.DeploymentTypes[0].Requirements | Where-Object { $_.Name -match $RuleName }
		}
		if ([System.String]::IsNullOrEmpty($Requirements)) {
			Add-LogContent "No Requirement rule was matched, tring one more thing for $RuleName"
			$Requirements = $SourceApplication.DeploymentTypes[0].Requirements | Where-Object { $_.Name -like $RuleName }
		}
		Add-LogContent "$($Requirements.Name) will be added"

		# apply requirement rules
		$Requirements | ForEach-Object {
     
			$RuleExists = $DestApplication.DeploymentTypes[$DestDeploymentTypeIndex].Requirements | Where-Object { $_.Name -match $RuleName }
			if ($RuleExists) {
 
				Add-LogContent "WARN: The rule `"$($_.Name)`" already exists in target application deployment type"
 
			}
			else {
         
				Add-LogContent "Apply rule `"$($_.Name)`" on target application deployment type"
 
				# create new rule ID
				$_.RuleID = "Rule_$( [guid]::NewGuid())"
 
				$DestApplication.DeploymentTypes[$DestDeploymentTypeIndex].Requirements.Add($_)
			}
		}
 
		# push changes
		$CMApplication = ConvertFrom-CMApplication -Application $DestApplication
		$CMApplication.Put()
		Pop-Location
	}

	function Add-RequirementsRule {
		[CmdletBinding()]
		param (
			[Parameter(Mandatory)]
			[ValidateSet('Value', 'Existential', 'OperatingSystem')]
			[String]
			$ReqRuleType,
			[Parameter()]
			[ValidateSet( 'And', 'Or', 'Other', 'IsEquals', 'NotEquals', 'GreaterThan', 'LessThan', 'Between', 'NotBetween', 'GreaterEquals', 'LessEquals', 'BeginsWith', 'NotBeginsWith', 'EndsWith', 'NotEndsWith', 'Contains', 'NotContains', 'AllOf', 'OneOf', 'NoneOf', 'SetEquals', 'SubsetOf', 'ExcludesAll')]
			$ReqRuleOperator,
			[Parameter(Mandatory)]
			[String[]]
			$ReqRuleValue,
			[Parameter()]
			[String[]]
			$ReqRuleValue2,
			[Parameter()]
			[String]
			$ReqRuleGlobalConditionName,
			[Parameter(Mandatory)]
			[String]
			$ReqRuleApplicationName,
			[Parameter(Mandatory)]
			[String]
			$ReqRuleApplicationDTName
		)
		
		Push-Location
		Set-Location $Global:CMSite
		Write-Host "`"$ReqRuleType of $ReqRuleGlobalConditionName $ReqRuleOperator $ReqRuleValue`" is being added"

		if (-not ([System.String]::IsNullOrEmpty($ReqRuleValue))) {
			$ReqRuleValueName = $ReqRuleValue
			#if (($ReqRuleOperator -eq 'Oneof') -or ($ReqRuleOperator -eq 'Noneof') -or ($ReqRuleOperator -eq 'Allof') -or ($ReqRuleOperator -eq 'Subsetof') -or ($ReqRuleOperator -eq 'ExcludesAll')) {
			if ($ReqRuleValue[1]) {
				$ReqRuleVal = $ReqRuleValue
				$ReqRuleValueName = "{ $($ReqRuleVal -join ", ") }"
			}
			if ([system.string]::IsNullOrEmpty($ReqRuleVal)) {
				$ReqRuleVal = $ReqRuleValue[0]
			}
		}
		
		if (-not ([System.String]::IsNullOrEmpty($ReqRuleValue2))) {
			if ($ReqRuleValue2[1]) {
				$ReqRuleVal2 = $ReqRuleValue2
				$ReqRuleValue2Name = "{ $($ReqRuleVal2 -join ", ") }"
			}
			if ([system.string]::IsNullOrEmpty($ReqRuleVal)) {
				$ReqRuleVal2 = $ReqRuleValue2[0]
			}
		}

		switch ($ReqRuleType) {
			Existential {
				Add-LogContent "Existential Rule $ReqRuleVal"
				$CMGlobalCondition = Get-CMGlobalCondition -Name $ReqRuleGlobalConditionName
				if ([System.Convert]::ToBoolean($ReqRuleVal)) {
					$rule = $CMGlobalCondition | New-CMRequirementRuleExistential -Existential $([System.Convert]::ToBoolean($($ReqRuleVal | Select-Object -first 1)))
					$rule.Name = "Existential of $ReqRuleGlobalConditionName Not equal to 0"
				}
				else {
					$rule = $CMGlobalCondition | New-CMRequirementRuleExistential -Existential $([System.Convert]::ToBoolean($($ReqRuleVal | Select-Object -first 1)))
					$rule.Name = "Existential of $ReqRuleGlobalConditionName Equals 0"
				}
			}
			OperatingSystem {
				Add-LogContent "Operating System $ReqRuleOperator `"$ReqruleVal`""
				# Only supporting Windows Operating Systems at this time
				$GlobalCondition = Get-CMGlobalCondition -name "Operating System" | Where-Object PlatformType -eq 1
				$rule = $GlobalCondition | New-CMRequirementRuleOperatingSystemValue -RuleOperator $ReqRuleOperator -PlatformStrings $ReqRuleVal
				$rule.Name = "Operating System $Global:OperatorsLookup $ReqRuleValueName"
			}
			Default {
				# DEFAULT TO VALUE
				Add-LogContent "Value $ReqRuleOperator `"$ReqRuleVal`""
				$CMGlobalCondition = Get-CMGlobalCondition -Name $ReqRuleGlobalConditionName
				if ([System.String]::IsNullOrEmpty($ReqRuleValue2)) {
					$rule = $CMGlobalCondition | New-CMRequirementRuleCommonValue -Value1 $ReqRuleVal -RuleOperator $ReqRuleOperator
					$rule.Name = "$ReqRuleGlobalConditionName $Global:OperatorsLookup $ReqRuleValueName"
				}
				else {
					$rule = $CMGlobalCondition | New-CMRequirementRuleCommonValue -Value1 $ReqRuleVal -RuleOperator $ReqRuleOperator -Value2 $ReqRuleVal2
					$rule.Name = "$ReqRuleGlobalConditionName $Global:OperatorsLookup $ReqRuleValueName $ReqRuleValue2Name"
				}
			}
		}

		Add-LogContent "Adding Requirement to $ReqRuleApplicationName, $ReqRuleApplicationDTName"
		Get-CMDeploymentType -ApplicationName $ReqRuleApplicationName -DeploymentTypeName $ReqRuleApplicationDTName | Set-CMDeploymentType -AddRequirement $rule
		Pop-Location
	}


	Function Add-CMDeploymentTypeProcessDetection {
		# Creates a Deployment Type Process Detection "Install Behavior tab in Deployment types".
		Param (
			[System.String]$DestApplicationName,
			[System.String]$DestDeploymentTypeName,
			[System.String]$ProcessDetectionDisplayName,
			[System.String]$ProcessDetectionExecutable
		)
		Push-Location
		Set-Location $CMSite
		$DestDeploymentTypeIndex = 0
 
		# get the applications
		$DestApplication = Get-CMApplication -Name $DestApplicationName | ConvertTo-CMApplication
	
		# Get DestDeploymentTypeIndex by finding the Title
		$DestDeploymentTypeIndex = $DestApplication.DeploymentTypes.Title.IndexOf($DestDeploymentTypeName)
    
		# Create Process Detection and set variables
		$ProcessInfo = [Microsoft.ConfigurationManagement.ApplicationManagement.ProcessInformation]::new()
		$ProcessInfo.DisplayInfo.Add(@{"DisplayName" = $ProcessDetectionDisplayName; Language = $NULL })
		$ProcessInfo.Name = $ProcessDetectionExecutable
 
		# push changes
		$DestApplication.DeploymentTypes[$DestDeploymentTypeIndex].Installer.InstallProcessDetection.ProcessList.Add($ProcessInfo)
		$CMApplication = ConvertFrom-CMApplication -Application $DestApplication
		$CMApplication.Put()
		Pop-Location
	}

	Function New-CMDeploymentTypeProcessRequirement {
		# Creates a Deployment Type Process Requirement "Install Behavior tab in Deployment types" by copying an existing Process Requirement.
		# LEGACY
		Param (
			[System.String]$SourceApplicationName,
			[System.String]$DestApplicationName,
			[System.String]$DestDeploymentTypeName,
			[System.String]$ProcessDetectionDisplayName,
			[System.String]$ProcessDetectionExecutable
		)
		Push-Location
		Set-Location $CMSite
		$DestDeploymentTypeIndex = 0
 
		# get the applications
		$SourceApplication = Get-CMApplication -Name $SourceApplicationName | ConvertTo-CMApplication
		$DestApplication = Get-CMApplication -Name $DestApplicationName | ConvertTo-CMApplication
	
		# Get DestDeploymentTypeIndex by finding the Title
		$DestDeploymentTypeIndex = $DestApplication.DeploymentTypes.Title.IndexOf($DestDeploymentTypeName)
    
		# Get requirement rules from source application
		$ProcessRequirementsList = $SourceApplication.DeploymentTypes[0].Installer.InstallProcessDetection.ProcessList[0]
		$ProcessRequirementsList
		if (-not ([System.String]::IsNullOrEmpty($ProcessRequirementsList))) {
			$ProcessRequirementsList.Name = $ProcessDetectionExecutable
			$ProcessRequirementsList.DisplayInfo[0].DisplayName = $ProcessDetectionDisplayName
			$ProcessRequirementsList
			$DestApplication.DeploymentTypes[$DestDeploymentTypeIndex].Installer.InstallProcessDetection.ProcessList.Add($ProcessRequirementsList)
		}
 
		# push changes
		$CMApplication = ConvertFrom-CMApplication -Application $DestApplication
		$CMApplication.Put()
		Pop-Location
	}

	Function Add-DeploymentType {
		Param (
			$Recipe
		)
	
		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		$ApplicationPublisher = $Recipe.ApplicationDef.Application.Publisher
		$ApplicationDescription = $Recipe.ApplicationDef.Application.Description
		$ApplicationDocURL = $Recipe.ApplicationDef.Application.UserDocumentation
	
		## Set Return Value to True, It will toggle to False if something Fails
		$DepTypeReturn = $true
	
		## Loop through each Deployment Type and Add them to the Application as needed
		ForEach ($DeploymentType In $Recipe.ApplicationDef.DeploymentTypes.ChildNodes) {
			$DepTypeName = $DeploymentType.Name
			$DepTypeDeploymentTypeName = $DeploymentType.DeploymentTypeName
			Add-LogContent "New DeploymentType - $DepTypeDeploymentTypeName"
		
			$AssociatedDownload = $Recipe.ApplicationDef.Downloads.Download | Where-Object DeploymentType -eq $DepTypeName
			$ApplicationSWVersion = $AssociatedDownload.Version
			$Version = $AssociatedDownload.Version
			If (-not ([String]::IsNullOrEmpty($AssociatedDownload.FullVersion))) {
				$FullVersion = $AssociatedDownload.FullVersion
			}
		
			# General
			$DepTypeApplicationName = "$ApplicationName $ApplicationSWVersion"
			$DepTypeInstallationType = $DeploymentType.InstallationType
			Add-LogContent "Deployment Type Set as: $DepTypeInstallationType"
		
			$stDepTypeComment = $DeploymentType.Comments
			$DepTypeLanguage = $DeploymentType.Language
		
			# Content Settings
			# Content Location
			If ([String]::IsNullOrEmpty($AssociatedDownload.AppRepoFolder)) {
				$DepTypeContentLocation = "$Global:ContentLocationRoot\$ApplicationName\Packages\$Version"
			}
			Else {
				$DepTypeContentLocation = "$Global:ContentLocationRoot\$ApplicationName\Packages\$Version\$($AssociatedDownload.AppRepoFolder)"
			}
			$swDepTypeCacheContent = [System.Convert]::ToBoolean($DeploymentType.CacheContent)
			$swDepTypeEnableBranchCache = [System.Convert]::ToBoolean($DeploymentType.BranchCache)
			$swDepTypeContentFallback = [System.Convert]::ToBoolean($DeploymentType.ContentFallback)
			$stDepTypeSlowNetworkDeploymentMode = $DeploymentType.OnSlowNetwork
		
			# Programs
			if (-not ([System.String]::IsNullOrEmpty($DeploymentType.InstallProgram))) {
				$DepTypeInstallationProgram = ($DeploymentType.InstallProgram).replace('$Version', $Version).replace('$FullVersion', $AppFullVersion)
			}
			
			if (-not ([System.String]::IsNullOrEmpty($DeploymentType.UninstallCmd))) {
				$stDepTypeUninstallationProgram = $DeploymentType.UninstallCmd
				$stDepTypeUninstallationProgram = ($stDepTypeUninstallationProgram).replace('$Version', $Version).replace('$FullVersion', $AppFullVersion)
			}
			$swDepTypeForce32Bit = [System.Convert]::ToBoolean($DeploymentType.Force32bit)
		
			# User Experience
			$stDepTypeInstallationBehaviorType = $DeploymentType.InstallationBehaviorType
			$stDepTypeLogonRequirementType = $DeploymentType.LogonReqType
			$stDepTypeUserInteractionMode = $DeploymentType.UserInteractionMode
			$swDepTypeRequireUserInteraction = [System.Convert]::ToBoolean($DeploymentType.ReqUserInteraction)
			$stDepTypeEstimatedRuntimeMins = $DeploymentType.EstRuntimeMins
			$stDepTypeMaximumRuntimeMins = $DeploymentType.MaxRuntimeMins
			$stDepTypeRebootBehavior = $DeploymentType.RebootBehavior
		
			# Because I hate the yellow squiggly lines
			Write-Output $ApplicationPublisher, $ApplicationDescription, $ApplicationDocURL, $DepTypeLanguage, $stDepTypeComment, $swDepTypeCacheContent, $swDepTypeEnableBranchCache, $swDepTypeContentFallback, $stDepTypeSlowNetworkDeploymentMode, $swDepTypeForce32Bit, $stDepTypeInstallationBehaviorType, $stDepTypeLogonRequirementType, $stDepTypeUserInteractionMode$swDepTypeRequireUserInteraction, $stDepTypeEstimatedRuntimeMins, $stDepTypeMaximumRuntimeMins, $stDepTypeRebootBehavior | Out-Null

			$DepTypeDetectionMethodType = $DeploymentType.DetectionMethodType
			Add-LogContent "Detection Method Type Set as $DepTypeDetectionMethodType"
			$DepTypeAddDetectionMethods = $false
		
			If (($DepTypeDetectionMethodType -eq "Custom") -and (-not ([System.String]::IsNullOrEmpty($DeploymentType.CustomDetectionMethods.ChildNodes)))) {
				$DepTypeDetectionMethods = @()
				$DepTypeAddDetectionMethods = $true
				$DepTypeDetectionClauseConnector = @()
				Add-LogContent "Adding Detection Method Clauses"
				ForEach ($DetectionMethod In $($DeploymentType.CustomDetectionMethods.ChildNodes | Where-Object Name -NE "DetectionClauseExpression")) {
					Add-LogContent "New Detection Method Clause $Version $FullVersion"
					$DepTypeDetectionMethods += Add-DetectionMethodClause -DetectionMethod $DetectionMethod -AppVersion $Version -AppFullVersion $FullVersion
				}
				if (-not [System.string]::IsNullOrEmpty($($DeploymentType.CustomDetectionMethods.ChildNodes | Where-Object Name -EQ "DetectionClauseExpression"))) {
					$CustomDetectionMethodExpression = ($DeploymentType.CustomDetectionMethods.ChildNodes | Where-Object Name -EQ "DetectionClauseExpression").ChildNodes
				}
				ForEach ($DetectionMethodExpression In $CustomDetectionMethodExpression) {
					if ($DetectionMethodExpression.Name -eq "DetectionClauseConnector") {
						Add-LogContent "New Detection Clause Connector $($DetectionMethodExpression.ConnectorClause),$($DetectionMethodExpression.ConnectorClauseConnector)"
						$DepTypeDetectionClauseConnector += @{"LogicalName" = $DepTypeDetectionMethods[$DetectionMethodExpression.ConnectorClause].Setting.LogicalName; "Connector" = "$($DetectionMethodExpression.ConnectorClauseConnector)" }
					}
					if ($DetectionMethodExpression.Name -eq "DetectionClauseGrouping") {
						Add-LogContent "New Detection Clause Grouping Statement Found - NOT READY YET"
					}
				}
			}
		
			Switch ($DepTypeInstallationType) {
				Script {
					Write-Host "Script Deployment"
					$DepTypeCommand = "Add-CMScriptDeploymentType -ApplicationName `"$DepTypeApplicationName`" -ContentLocation `"$DepTypeContentLocation`" -DeploymentTypeName `"$DepTypeDeploymentTypeName`""
					$CmdSwitches = ""
				
					## Build the Rest of the command based on values in the xml
					## Switch type Arguments
					ForEach ($DepTypeVar In $(Get-Variable | Where-Object {
								$_.Name -like "swDepType*"
							})) {
						If (([System.Convert]::ToBoolean($deptypevar.Value)) -and (-not ([System.String]::IsNullOrEmpty($DepTypeVar.Value)))) {
							$CmdSwitch = "-$($($DepTypeVar.Name).Replace("swDepType", ''))"
							$CmdSwitches += " $CmdSwitch"
						}
					}
				
					## String Type Arguments
					ForEach ($DepTypeVar In $(Get-Variable | Where-Object {
								$_.Name -like "stDepType*"
							})) {
						If (-not ([System.String]::IsNullOrEmpty($DepTypeVar.Value))) {
							$CmdSwitch = "-$($($DepTypeVar.Name).Replace("stDepType", '')) `"$($DepTypeVar.Value)`""
							$CmdSwitches += " $CmdSwitch"
						}
					}
				
					## Script Install Type Specific Arguments
					$CmdSwitches += " -InstallCommand `'$DepTypeInstallationProgram`'"
				
					If ($DepTypeDetectionMethodType -eq "CustomScript") {
						$DepTypeScriptLanguage = $DeploymentType.ScriptLanguage
						If (-not ([string]::IsNullOrEmpty($DepTypeScriptLanguage))) {
							$CMDSwitch = "-ScriptLanguage `"$DepTypeScriptLanguage`""
							$CmdSwitches += " $CmdSwitch"
						}
					
						$DepTypeScriptText = ($DeploymentType.DetectionMethod).Replace('$Version', $Version).replace('$FullVersion', $AppFullVersion)
						If (-not ([string]::IsNullOrEmpty($DepTypeScriptText))) {
							$CMDSwitch = "-ScriptText `'$DepTypeScriptText`'"
							$CmdSwitches += " $CmdSwitch"
						}
					}
				
					$DepTypeForce32BitDetection = $DeploymentType.ScriptDetection32Bit
					If (([System.Convert]::ToBoolean($DepTypeForce32BitDetection)) -and (-not ([System.String]::IsNullOrEmpty($DepTypeForce32BitDetection)))) {
						$CmdSwitches += " -ForceScriptDetection32Bit"
					}
				
					## Run the Add-CMApplicationDeployment Command
					$DeploymentTypeCommand = "$DepTypeCommand$CmdSwitches"
					If ($DepTypeAddDetectionMethods) {
						$DeploymentTypeCommand += " -ScriptType Powershell -ScriptText `"write-output 0`""
					}
					Add-LogContent "Creating DeploymentType"
					Add-LogContent "Command: $DeploymentTypeCommand"
					Push-Location
					Set-Location $CMSite
					Try {
						Invoke-Expression $DeploymentTypeCommand | Out-Null
					}
					Catch {
						$ErrorMessage = $_.Exception.Message
						$FullyQualified = $_.Exeption.FullyQualifiedErrorID
						Add-LogContent "ERROR: Creating Deployment Type Failed!"
						Add-LogContent "ERROR: $ErrorMessage"
						Add-LogContent "ERROR: $FullyQualified"
						$DepTypeReturn = $false
					}
				
					## Add Detection Methods if required for this Deployment Type
					If ($DepTypeAddDetectionMethods) {
						Add-LogContent "Adding Detection Methods"
					
						Add-LogContent "Number of Detection Methods: $($DepTypeDetectionMethods.Count)"
						if ($DepTypeDetectionMethods.Count -eq 1) {
					
							Add-LogContent "Set-CMScriptDeploymentType -ApplicationName $DepTypeApplicationName -DeploymentTypeName $DepTypeDeploymentTypeName -AddDetectionClause $($DepTypeDetectionMethods[0].DataType.Name)"
							Try {
								Set-CMScriptDeploymentType -ApplicationName "$DepTypeApplicationName" -DeploymentTypeName "$DepTypeDeploymentTypeName" -AddDetectionClause $DepTypeDetectionMethods
							}
							Catch {
								Write-Host $_
								$ErrorMessage = $_.Exception.Message
								$FullyQualified = $_.Exeption.FullyQualifiedErrorID
								Add-LogContent "ERROR: Adding Detection Method Failed!"
								Add-LogContent "ERROR: $ErrorMessage"
								Add-LogContent "ERROR: $FullyQualified"
								$DepTypeReturn = $false
							}
						} 
						Else {
							Add-LogContent "Set-CMScriptDeploymentType -ApplicationName $DepTypeApplicationName -DeploymentTypeName $DepTypeDeploymentTypeName -AddDetectionClause $($DepTypeDetectionMethods[0].DataType.Name) -DetectionClauseConnector $DepTypeDetectionClauseConnector"
							Try {	
								Set-CMScriptDeploymentType -ApplicationName "$DepTypeApplicationName" -DeploymentTypeName "$DepTypeDeploymentTypeName" -AddDetectionClause $DepTypeDetectionMethods -DetectionClauseConnector $DepTypeDetectionClauseConnector
							}
							Catch {
								Write-Host $_
								$ErrorMessage = $_.Exception.Message
								$FullyQualified = $_.Exeption.FullyQualifiedErrorID
								Add-LogContent "ERROR: Adding Detection Method Failed!"
								Add-LogContent "ERROR: $ErrorMessage"
								Add-LogContent "ERROR: $FullyQualified"
								$DepTypeReturn = $false
							}	
						}		
					}
					Pop-Location	
				}
				MSI {
					Write-Host "MSI Deployment"
					$DepTypeInstallationMSI = $DeploymentType.InstallationMSI
					$DepTypeCommand = "Add-CMMsiDeploymentType -ApplicationName `"$DepTypeApplicationName`" -ContentLocation `"$DepTypeContentLocation\$DepTypeInstallationMSI`" -DeploymentTypeName `"$DepTypeDeploymentTypeName`""
					$CmdSwitches = ""
					## Build the Rest of the command based on values in the xml
					ForEach ($DepTypeVar In $(Get-Variable | Where-Object {
								$_.Name -like "swDepType*"
							})) {
						If (([System.Convert]::ToBoolean($deptypevar.Value)) -and (-not ([System.String]::IsNullOrEmpty($DepTypeVar.Value)))) {
							$CmdSwitch = "-$($($DepTypeVar.Name).Replace("swDepType", ''))"
							$CmdSwitches += " $CmdSwitch"
						}
					}
				
					ForEach ($DepTypeVar In $(Get-Variable | Where-Object {
								$_.Name -like "stDepType*"
							})) {
						If (-not ([System.String]::IsNullOrEmpty($DepTypeVar.Value))) {
							$CmdSwitch = "-$($($DepTypeVar.Name).Replace("stDepType", '')) `"$($DepTypeVar.Value)`""
							$CmdSwitches += " $CmdSwitch"
						}
					}
				
					## Special Arguments based on Detection Method
					Switch ($DepTypeDetectionMethodType) {
						MSI {
							If (-not ([string]::IsNullOrEmpty($DepTypeInstallationProgram))) {
								$CmdSwitches += " -InstallCommand `"$DepTypeInstallationProgram`""
							}
						
							$DepTypeProductCode = $DeploymentType.ProductCode
							If (-not ([string]::IsNullOrEmpty($DepTypeProductCode))) {
								$CMDSwitch = "-ProductCode `"$DepTypeProductCode`""
								$CmdSwitches += " $CmdSwitch"
							}
						}
						CustomScript {
							$CmdSwitches += " -InstallCommand `"$DepTypeInstallationProgram`""
						
							$DepTypeScriptLanguage = $DeploymentType.ScriptLanguage
							If (-not ([string]::IsNullOrEmpty($DepTypeScriptLanguage))) {
								$CMDSwitch = "-ScriptLanguage `"$DepTypeScriptLanguage`""
								$CmdSwitches += " $CmdSwitch"
							}
						
							$DepTypeForce32BitDetection = $DeploymentType.ScriptDetection32Bit
							If (([System.Convert]::ToBoolean($DepTypeForce32BitDetection)) -and (-not ([System.String]::IsNullOrEmpty($DepTypeForce32BitDetection)))) {
								$CmdSwitches += " -ForceScriptDetection32Bit"
							}
						
							$DepTypeScriptText = ($DeploymentType.DetectionMethod).Replace("REPLACEMEWITHTHEAPPVERSION", $($AssociatedDownload.Version))
							If (-not ([string]::IsNullOrEmpty($DepTypeScriptText))) {
								$CMDSwitch = "-ScriptText `'$DepTypeScriptText`'"
								$CmdSwitches += " $CmdSwitch"
							}
						}
					}
				
					## Run the Add-CMApplicationDeployment Command
					Push-Location
					Set-Location $CMSite
					$DeploymentTypeCommand = "$DepTypeCommand$CmdSwitches -Force"
					Add-LogContent "Creating DeploymentType"
					Add-LogContent "Command: $DeploymentTypeCommand"
					Try {
						Invoke-Expression $DeploymentTypeCommand | Out-Null
					}
					Catch {
						$ErrorMessage = $_.Exception.Message
						$FullyQualified = $_.Exeption.FullyQualifiedErrorID
						Add-LogContent "ERROR: Adding MSI Deployment Type Failed!"
						Add-LogContent "ERROR: $ErrorMessage"
						Add-LogContent "ERROR: $FullyQualified"
						$DepTypeReturn = $false
					}
					If ($DepTypeAddDetectionMethods) {
						Add-LogContent "Adding Detection Methods"
					
						Add-LogContent "Number of Detection Methods: $($DepTypeDetectionMethods.Count)"
						if ($DepTypeDetectionMethods.Count -eq 1) {
							Add-LogContent "Set-CMMsiDeploymentType -ApplicationName $DepTypeApplicationName -DeploymentTypeName $DepTypeDeploymentTypeName -AddDetectionClause $($DepTypeDetectionMethods[0].DataType.Name)"
							Try {
								Set-CMMsiDeploymentType -ApplicationName "$DepTypeApplicationName" -DeploymentTypeName "$DepTypeDeploymentTypeName" -AddDetectionClause $DepTypeDetectionMethods
							}
							Catch {
								$ErrorMessage = $_.Exception.Message
								$FullyQualified = $_.Exeption.FullyQualifiedErrorID
								Add-LogContent "ERROR: Adding Detection Method Failed!"
								Add-LogContent "ERROR: $ErrorMessage"
								Add-LogContent "ERROR: $FullyQualified"
								$DepTypeReturn = $false
							}
						}
						else {
							Add-LogContent "Set-CMMsiDeploymentType -ApplicationName $DepTypeApplicationName -DeploymentTypeName $DepTypeDeploymentTypeName -AddDetectionClause $($DepTypeDetectionMethods[0].DataType.Name) -"
							Try {
								Set-CMMsiDeploymentType -ApplicationName "$DepTypeApplicationName" -DeploymentTypeName "$DepTypeDeploymentTypeName" -AddDetectionClause $DepTypeDetectionMethods -DetectionClauseConnector $DepTypeDetectionClauseConnector
							}
							Catch {
								$ErrorMessage = $_.Exception.Message
								$FullyQualified = $_.Exeption.FullyQualifiedErrorID
								Add-LogContent "ERROR: Adding Detection Method Failed!"
								Add-LogContent "ERROR: $ErrorMessage"
								Add-LogContent "ERROR: $FullyQualified"
								$DepTypeReturn = $false
							}
						}
					}
					Pop-Location
				}			
				MSIX {
					# SOON(TM)
				}
				Default {
					$DepTypeReturn = $false
				}
			}

		
			## Add LEGACY Requirements for Deployment Type if they exist
			If (-not [System.String]::IsNullOrEmpty($DeploymentType.Requirements)) {
				Add-LogContent "Adding Requirements to $DepTypeDeploymentTypeName"
				$DepTypeRules = $DeploymentType.Requirements.RuleName
				ForEach ($DepTypeRule In $DepTypeRules) {
					Copy-CMDeploymentTypeRule -SourceApplicationName $RequirementsTemplateAppName -DestApplicationName $DepTypeApplicationName -DestDeploymentTypeName $DepTypeDeploymentTypeName -RuleName $DepTypeRule
				}
			}

			## Add NEW Requirements for Deployment Type is Necessary
			if (-not [System.String]::IsNullOrEmpty($DeploymentType.RequirementsRules)) {
				Add-LogContent "Adding Requirements to $DepTypeDeploymentTypeName"
				$DepTypeReqRules = $DeploymentType.RequirementsRules.RequirementsRule
				ForEach ($DepTypeReqRule In $DepTypeReqRules) {
					$addRequirementsRuleSplat = @{
						ReqRuleApplicationName   = $DepTypeApplicationName
						ReqRuleApplicationDTName = $DepTypeDeploymentTypeName
						ReqRuleValue             = @($DepTypeReqRule.RequirementsRuleValue.RuleValue)
						ReqRuleType              = $DepTypeReqRule.RequirementsRuleType
					}
					
					if (-not ([system.string]::IsNullOrEmpty($DepTypeReqRule.RequirementsRuleGlobalCondition))) {
						$addRequirementsRuleSplat.Add("ReqRuleGlobalConditionName", $DepTypeReqRule.RequirementsRuleGlobalCondition)
					}

					if (-not ([system.string]::IsNullOrEmpty($DepTypeReqRule.RequirementsRuleOperator))) {
						$addRequirementsRuleSplat.Add("ReqRuleOperator", $DepTypeReqRule.RequirementsRuleOperator)
					}

					if (-not ([system.string]::IsNullOrEmpty($DepTypeReqRule.RequirementsRuleValue2))) {
						$addRequirementsRuleSplat.Add("ReqRuleValue2", $DepTypeReqRule.ReqRuleValue2.RuleValue)
					}
					Write-Output "Add-RequirementsRule $addRequirementsRuleSplat"
					Add-RequirementsRule @addRequirementsRuleSplat
				}
			}
        
			## Add Install Behavior for Deployment Type if they exist
			If (-not [System.String]::IsNullOrEmpty($DeploymentType.InstallBehavior)) {
				Add-LogContent "Adding Install Behavior to $DepTypeDeploymentTypeName"
				$DepTypeInstallBehaviorProcesses = $DeploymentType.InstallBehavior.InstallBehaviorProcess
				ForEach ($DepTypeInstallBehavior In $DepTypeInstallBehaviorProcesses) {
					$newCMDeploymentTypeProcessRequirementSplat = @{
						ProcessDetectionDisplayName = $DepTypeInstallBehavior.DisplayName
						DestApplicationName         = $DepTypeApplicationName
						ProcessDetectionExecutable  = $DepTypeInstallBehavior.InstallBehaviorExe
						DestDeploymentTypeName      = $DepTypeDeploymentTypeName
					}
					Add-CMDeploymentTypeProcessDetection @newCMDeploymentTypeProcessRequirementSplat
				}
			}
		
			## Add Dependencies for Deployment Type if they exist
			if (-not [System.String]::IsNullOrEmpty($DeploymentType.Dependencies)) {
				Add-LogContent "Adding Dependencies to $DepTypeDeploymentTypeName"
				$DepTypeDependencyGroups = $DeploymentType.Dependencies.DependencyGroup
				foreach ($DepTypeDependencyGroup in $DepTypeDependencyGroups) {
					Add-LogContent "Creating Dependency Group $($DepTypeDependencyGroup.GroupName) on $DepTypeDeploymentTypeName"
					Push-Location
					Set-Location $CMSite
					$DependencyGroup = Get-CMDeploymentType -ApplicationName $DepTypeApplicationName -DeploymentTypeName $DepTypeDeploymentTypeName | New-CMDeploymentTypeDependencyGroup -GroupName $DepTypeDependencyGroup.GroupName
					$DepTypeDependencyGroupApps = $DepTypeDependencyGroup.DependencyGroupApp
					foreach ($DepTypeDependencyGroupApp in $DepTypeDependencyGroupApps) {
						$DependencyGroupAppAutoInstall = [System.Convert]::ToBoolean($DepTypeDependencyGroupApp.DependencyAutoInstall)
						$DependencyAppName = ((Get-CMApplication $DepTypeDependencyGroupApp.AppName | Sort-Object -Property Version -Descending | Select-Object -First 1).LocalizedDisplayName)
						if (-not [System.String]::IsNullOrEmpty($DepTypeDependencyGroupApp.DependencyDepType)) {
							Add-LogContent "Selecting Deployment Type for App Dependency: $($DepTypeDependencyGroupApp.DependencyDepType)"
							$DependencyAppObject = Get-CMDeploymentType -ApplicationName $DependencyAppName -DeploymentTypeName "$($DepTypeDependencyGroupApp.DependencyDepType)"
						}
						else {
							$DependencyAppObject = Get-CMDeploymentType -ApplicationName $DependencyAppName
						}
						$DependencyGroup | Add-CMDeploymentTypeDependency -DeploymentTypeDependency $DependencyAppObject -IsAutoInstall $DependencyGroupAppAutoInstall
					}
					Pop-Location
				}
			}
		}
		Return $DepTypeReturn
	}

	Function Invoke-ApplicationDistribution {
		Param (
			$Recipe
		)
		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		ForEach ($Download In ($Recipe.ApplicationDef.Downloads.Download)) {
			If (-not ([System.String]::IsNullOrEmpty($Download.Version))) {
				$ApplicationSWVersion = $Download.Version
			}
		}
		$Success = $true
		## Distributes the Content for the Created Application based on the Information in the Recipe XML under the Distribution Node
		Push-Location
		Set-Location $CMSite
		$DistContent = [System.Convert]::ToBoolean($Recipe.ApplicationDef.Distribution.DistributeContent)
		If ($DistContent) {
			If (-not ([string]::IsNullOrEmpty($Recipe.ApplicationDef.Distribution.DistributeToGroup))) {
				$DistributionGroup = $Recipe.ApplicationDef.Distribution.DistributeToGroup
				Add-LogContent "Distributing Content for $ApplicationName $ApplicationSWVersion to $($Recipe.ApplicationDef.Distribution.DistributeToGroup)"
				Try {
					Start-CMContentDistribution -ApplicationName "$ApplicationName $ApplicationSWVersion" -DistributionPointGroupName $DistributionGroup -ErrorAction Stop
				}
				Catch {
					$ErrorMessage = $_.Exception.Message
					Add-LogContent "ERROR: Content Distribution Failed!"
					Add-LogContent "ERROR: $ErrorMessage"
					$Success = $false
				}
			}
			If (-not ([string]::IsNullOrEmpty($Recipe.ApplicationDef.Distribution.DistributeToDPs))) {
				Add-LogContent "Distributing Content to $($Recipe.ApplicationDef.Distribution.DistributeToDPs)"
				$DistributionDPs = ($Recipe.ApplicationDef.Distribution.DistributeToDPs).Split(",")
				ForEach ($DistributionPoint In $DistributionDPs) {
					Try {
						Start-CMContentDistribution -ApplicationName "$ApplicationName $ApplicationSWVersion" -DistributionPointName $DistributionPoint -ErrorAction Stop
					}
					Catch {
						$ErrorMessage = $_.Exception.Message
						Add-LogContent "ERROR: Content Distribution Failed!"
						Add-LogContent "ERROR: $ErrorMessage"
						$Success = $false
					}
				}
			}
			If ((([string]::IsNullOrEmpty($Recipe.ApplicationDef.Distribution.DistributeToDPs)) -and ([string]::IsNullOrEmpty($Recipe.ApplicationDef.Distribution.DistributeToGroup))) -and (-not ([String]::IsNullOrEmpty($Global:PreferredDistributionLoc)))) {
				$DistributionGroup = $Global:PreferredDistributionLoc
				Add-LogContent "Distribution was set to True but No Distribution Points or Groups were Selected, Using Preferred Distribution Group: $Global:PreferredDistributionLoc"
				Try {
					Start-CMContentDistribution -ApplicationName "$ApplicationName $ApplicationSWVersion" -DistributionPointGroupName $DistributionGroup -ErrorAction Stop
				}
				Catch {
					$ErrorMessage = $_.Exception.Message
					Add-LogContent "ERROR: Content Distribution Failed!"
					Add-LogContent "ERROR: $ErrorMessage"
					$Success = $false
				}
			}
		}
		Pop-Location
		Return $Success
	}

	Function Invoke-ApplicationDeployment {
		Param (
			$Recipe
		)
	
		$Success = $true
		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		ForEach ($Download In ($Recipe.ApplicationDef.Downloads.Download)) {
			If (-not ([System.String]::IsNullOrEmpty($Download.Version))) {
				$ApplicationSWVersion = $Download.Version
			}
		}
	
		## Deploys the Created application based on the Information in the Recipe XML under the Deployment Node
		Push-Location
		Set-Location $CMSite
		If ([System.Convert]::ToBoolean($Recipe.ApplicationDef.Deployment.DeploySoftware)) {
			If (-not ([string]::IsNullOrEmpty($Recipe.ApplicationDef.Deployment.DeploymentCollection))) {
				Foreach ($DeploymentCollection in ($Recipe.ApplicationDef.Deployment.DeploymentCollection)) {
					Try {
						Add-LogContent "Deploying $ApplicationName $ApplicationSWVersion to $DeploymentCollection"
						New-CMApplicationDeployment -CollectionName $DeploymentCollection -Name "$ApplicationName $ApplicationSWVersion" -DeployAction Install -DeployPurpose Available -UserNotification DisplaySoftwareCenterOnly -ErrorAction Stop
					}
					Catch {
						$ErrorMessage = $_.Exception.Message
						Add-LogContent "ERROR: Deployment Failed!"
						Add-LogContent "ERROR: $ErrorMessage"
						$Success = $false
					}
				}
			}
			ElseIf (-not ([String]::IsNullOrEmpty($Global:PreferredDeployCollection))) {
				Try {
					Add-LogContent "Deploying $ApplicationName $ApplicationSWVersion to $Global:PreferredDeployCollection"
					New-CMApplicationDeployment -CollectionName $Global:PreferredDeployCollection -Name "$ApplicationName $ApplicationSWVersion" -DeployAction Install -DeployPurpose Available -UserNotification DisplaySoftwareCenterOnly -ErrorAction Stop
				}
				Catch {
					$ErrorMessage = $_.Exception.Message
					Add-LogContent "ERROR: Deployment Failed!"
					Add-LogContent "ERROR: $ErrorMessage"
					$Success = $false
				}
			}
		}
		Pop-Location
		Return $Success
	}

	function Invoke-ApplicationSupersedence {
		param (
			$Recipe
		)

		$ApplicationName = $Recipe.ApplicationDef.Application.Name
		$ApplicationPublisher = $Recipe.ApplicationDef.Application.Publisher
		$SupersedenceEnabled = [System.Convert]::ToBoolean($Recipe.ApplicationDef.Supersedence)
		Write-Output "Supersedence is $SupersedenceEnabled"
		if ($SupersedenceEnabled) {
			# Get the Previous Application Deployment Type
			Push-Location
			Set-Location $CMSite
			$Latest2Apps = Get-CMApplication -Name "$ApplicationName*" -Fast | Where-Object Publisher -eq $ApplicationPublisher | Sort-Object DateCreated | Select-Object -first 2
			if ($Latest2Apps.Count -eq 2) {
				$NewApp = $Latest2Apps[0]
				$OldApp = $Latest2Apps[1]
				Write-Output $oldapp.LocalizedDisplayName $newapp.LocalizedDisplayName
				# Check that the DeploymentTypes and Deployment Type Names Match if not, skip supersedence
				$NewAppDeploymentTypes = Get-CMDeploymentType -ApplicationName $NewApp.LocalizedDisplayName
				$OldAppDeploymentTypes = Get-CMDeploymentType -ApplicationName $OldApp.LocalizedDisplayName

				if ($NewAppDeploymentTypes.LocalizedDisplayName -eq $OldAppDeploymentTypes.LocalizedDisplayName) {
					Write-Output "New and Old App Deployment Type Names Match"
					Foreach ($DeploymentType in $NewAppDeploymentTypes) {
						Write-Host "Superseding $($DeploymentType.LocalizedDisplayName)"
						$SupersededDeploymentType = $OldAppDeploymentTypes | Where-Object LocalizedDisplayName -eq $DeploymentType.LocalizedDisplayName
						Add-CMDeploymentTypeSupersedence -SupersedingDeploymentType $DeploymentType -SupersededDeploymentType $SupersededDeploymentType
					}
				}
			}
			Pop-Location
		}
		Write-Output $true
	}

	Function Send-EmailMessage {
		Add-LogContent "Sending Email"
		$Global:EmailBody += "`n`nThis message was automatically generated"
		Try {
			Send-MailMessage -To $EmailTo -Subject $EmailSubject -From $EmailFrom -Body $Global:EmailBody -SmtpServer $EmailServer -ErrorAction Stop
		}
		Catch {
			$ErrorMessage = $_.Exception.Message
			Add-LogContent "ERROR: Sending Email Failed!"
			Add-LogContent "ERROR: $ErrorMessage"
		}
	}

	Function Connect-ConfigMgr {
		$Global:ConfigMgrConnection = $true
		$Global:ConfigMgrConnection | Out-Null
		if (-not (Get-Module ConfigurationManager)) {
			try {
				Add-LogContent "Importing ConfigurationManager Module"
				Import-Module (Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
			} 
			catch {
				$ErrorMessage = $_.Exception.Message
				Add-LogContent "ERROR: Importing ConfigurationManager Module Failed!"
				Add-LogContent "ERROR: $ErrorMessage"
				if (-not $Setup) {
					Exit 1
				}
				else {
					$Global:ConfigMgrConnection = $false
				}
			}
		}
	
		if ($null -eq (Get-PSDrive -Name $Global:SiteCode -ErrorAction SilentlyContinue)) {
			try {
				New-PSDrive -Name $Global:SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $Global:SiteServer
			}
			catch {
				Add-LogContent "ERROR - The CM PSDrive could not be loaded. Exiting..."
				Add-LogContent "ERROR: $ErrorMessage"
				if (-not $Setup) {
					Exit 1
				}
				else {
					$Global:ConfigMgrConnection = $false
				}
			}
		}
	}

	Function Start-OpenFolderDialog {
		[CmdletBinding()]
		param (
			[Parameter()]
			[String]
			$OpenFolderWindowTitle,
			[Parameter()]
			[String]
			$InitialDirectory
		)
		# Code from https://gist.github.com/IMJLA/1d570aa2bb5c30215c222e7a5e5078fd
		$AssemblyFullName = 'System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'
		$Assembly = [System.Reflection.Assembly]::Load($AssemblyFullName)
		$OpenFileDialog = [System.Windows.Forms.OpenFileDialog]::new()
		$OpenFileDialog.AddExtension = $false
		$OpenFileDialog.CheckFileExists = $false
		$OpenFileDialog.DereferenceLinks = $true
		if ((-not ([System.String]::IsNullOrEmpty($InitialDirectory))) -and (Test-Path $InitialDirectory -IsValid -ErrorAction SilentlyContinue)) {
			$OpenFileDialog.InitialDirectory = $InitialDirectory
		}
		$OpenFileDialog.Filter = "Folders|`n"
		$OpenFileDialog.Multiselect = $false
		if ([System.String]::IsNullOrEmpty($OpenFolderWindowTitle)) {
			$OpenFileDialog.Title = "Select folder"
		}
		else {
			$OpenFileDialog.Title = $OpenFolderWindowTitle
		}
		$OpenFileDialogType = $OpenFileDialog.GetType()
		$FileDialogInterfaceType = $Assembly.GetType('System.Windows.Forms.FileDialogNative+IFileDialog')
		$IFileDialog = $OpenFileDialogType.GetMethod('CreateVistaDialog', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $null)
		$null = $OpenFileDialogType.GetMethod('OnBeforeVistaDialog', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $IFileDialog)
		[uint32]$PickFoldersOption = $Assembly.GetType('System.Windows.Forms.FileDialogNative+FOS').GetField('FOS_PICKFOLDERS').GetValue($null)
		$FolderOptions = $OpenFileDialogType.GetMethod('get_Options', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $null) -bor $PickFoldersOption
		$null = $FileDialogInterfaceType.GetMethod('SetOptions', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $FolderOptions)
		$VistaDialogEvent = [System.Activator]::CreateInstance($AssemblyFullName, 'System.Windows.Forms.FileDialog+VistaDialogEvents', $false, 0, $null, $OpenFileDialog, $null, $null).Unwrap()
		[uint32]$AdviceCookie = 0
		$AdvisoryParameters = @($VistaDialogEvent, $AdviceCookie)
		$AdviseResult = $FileDialogInterfaceType.GetMethod('Advise', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $AdvisoryParameters)
		$AdviceCookie = $AdvisoryParameters[1]
		$Result = $FileDialogInterfaceType.GetMethod('Show', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, [System.IntPtr]::Zero)
		$null = $FileDialogInterfaceType.GetMethod('Unadvise', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $AdviceCookie)
		if ($Result -eq [System.Windows.Forms.DialogResult]::OK) {
			$FileDialogInterfaceType.GetMethod('GetResult', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $null)
		}
		Write-Output $OpenFileDialog.FileName
	}
	Function Test-GUItestConnectButton {
		if ((($WPFtextBoxSiteCode.Text -like "???") -or ($WPFtextBoxSiteCode.Text -like "???:")) -and (-not ([System.String]::IsNullOrEmpty($WPFtextBoxSiteServer.Text)))) {
			$WPFbuttonConnect.IsEnabled = $true
		}
		else {
			$WPFbuttonConnect.IsEnabled = $false
		}	
	}

	Function Test-SendEmailtoggleButton {
		$EmailValue = [bool]($WPFtoggleButtonSendEmail.IsChecked)
		$WPFtoggleButtonNotifyOnFailure.IsEnabled = $EmailValue
		$WPFlabelEmailFrom.IsEnabled = $EmailValue
		$WPFlabelEmailTo.IsEnabled = $EmailValue
		$WPFlabelEmailServer.IsEnabled = $EmailValue
		$WPFtextBoxEmailTo.IsEnabled = $EmailValue
		$WPFtextBoxEmailFrom.IsEnabled = $EmailValue
		$WPFtextBoxEmailServer.IsEnabled = $EmailValue
	}

	Function Update-GUI {
		# Connection
		if ((($WPFtextBoxSiteCode.Text -like "???") -or ($WPFtextBoxSiteCode.Text -like "???:")) -and (-not ([System.String]::IsNullOrEmpty($WPFtextBoxSiteServer.Text)))) {
			$WPFbuttonConnect.IsEnabled = $true
		}
		else {
			$WPFbuttonConnect.IsEnabled = $false
		}	

		# Collection Query
		if ($WPFButtonConnect.IsEnabled -and $Global:ConfigMgrConnection) {
			$WPFbuttonQueryCols.IsEnabled = $true
		}
		else {
			$WPFbuttonQueryCols.IsEnabled = $false
		}

		# Email Toggle
		$EmailValue = [bool]($WPFtoggleButtonSendEmail.IsChecked)
		$WPFtoggleButtonNotifyOnFailure.IsEnabled = $EmailValue
		$WPFlabelEmailFrom.IsEnabled = $EmailValue
		$WPFlabelEmailTo.IsEnabled = $EmailValue
		$WPFlabelEmailServer.IsEnabled = $EmailValue
		$WPFtextBoxEmailTo.IsEnabled = $EmailValue
		$WPFtextBoxEmailFrom.IsEnabled = $EmailValue
		$WPFtextBoxEmailServer.IsEnabled = $EmailValue
	}

	################################### MAIN ########################################
	## Startup
	if ($Setup) {
		$inputXML = Get-Content "$PSScriptRoot\ExtraFiles\Scripts\CMPackagerSetup.xaml" -Raw
		$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'
		[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
		[xml]$XAML = $inputXML
		#Read XAML
 
		$reader = (New-Object System.Xml.XmlNodeReader $xaml)
		try {
			$Form = [Windows.Markup.XamlReader]::Load( $reader )
		}
		catch {
			Write-Warning "Unable to parse XML, with error: $($Error[0])`n Ensure that there are NO SelectionChanged or TextChanged properties in your textboxes (PowerShell cannot process them)"
			throw
		}
 
		#===========================================================================
		# Load XAML Objects In PowerShell
		#===========================================================================
  
		$xaml.SelectNodes("//*[@Name]") | ForEach-Object { #"trying item $($_.Name)";
			try { Set-Variable -Name "WPF$($_.Name)" -Value $Form.FindName($_.Name) -ErrorAction Stop }
			catch { throw }
		}

		$WPFtoggleButtonSendEmail.Add_Click( {
				Update-GUI
			})

		$WPFtextBoxSiteCode.Add_LostFocus( {
				Update-GUI
			})

		$WPFtextBoxSiteCode.Add_TextChanged( {
				Update-GUI
			})

		$WPFtextBoxSiteServer.Add_TextChanged( {
				Update-GUI
			})

		$WPFbuttonQueryCols.Add_Click( {
				$form.Cursor = "Wait"
				Connect-ConfigMgr
				Push-Location
				Set-Location $Global:CMSite
				(Get-CMDeviceCollection -Name "$($WPFcomboBoxPreferredDeployColl.Text)*") | ForEach-Object { $WPFcomboBoxPreferredDeployColl.Items.Add($_.Name) }
				Pop-Location
				$form.Cursor = "Arrow"
			})

		$WPFbuttonConnect.Add_Click( {
				$Global:SiteCode = ($WPFtextBoxSiteCode.Text).replace(":", "")
				$Global:CMSite = "$($Global:SiteCode):"
				$Global:SiteServer = $WPFtextBoxSiteServer.Text
				$Global:SiteServer | Out-Null
				$form.Cursor = "Wait"
				Connect-ConfigMgr
				Push-Location
				Set-Location $Global:CMSite
				Get-CMDistributionPointGroup | ForEach-Object { $WPFcomboBoxPreferredDistPoint.Items.Add($_.Name) }
				Pop-Location
				$form.Cursor = "Arrow"
			})

		$WPFbuttonBrowseRoot.Add_Click( {
				$FileDialogResult = Start-OpenFolderDialog -OpenFolderWindowTitle "Select ConfigMgr Content Root Directory" -InitialDirectory $WPFtextBoxContentRoot.text
				if (-not ([System.String]::IsNullorEmpty($FileDialogResult))) {
					$WPFtextBoxContentRoot.text = $FileDialogResult
				}
			})

		$WPFbuttonBrowseIcon.Add_Click( {
				$FileDialogResult = Start-OpenFolderDialog -OpenFolderWindowTitle "Select Icon Repository Directory" -InitialDirectory $WPFtextBoxIconRepository.text
				if (-not ([System.String]::IsNullorEmpty($FileDialogResult))) {
					$WPFtextBoxIconRepository.text = $FileDialogResult
				}
			})

		$WPFbuttonBrowseWorkDir.Add_Click( {
				$FileDialogResult = Start-OpenFolderDialog -OpenFolderWindowTitle "Select CMPackager Working Directory" -InitialDirectory $WPFtextBoxWorkingDir.text
				if (-not ([System.String]::IsNullorEmpty($FileDialogResult))) {
					$WPFtextBoxWorkingDir.text = $FileDialogResult
				}
			})

		$Form.Add_ContentRendered( {
				foreach ($key in $Global:XMLtoDisplayHash.Keys) {
					Write-Host $key $XMLtoDisplayHash[$key]
					$Value = ($CMPackagerXML.PackagerPrefs.$key)
					$DisplayVariable = Get-Variable $XMLtoDisplayHash[$key] -ValueOnly
					switch -wildcard ($XMLtoDisplayHash[$key]) {
						*toggleButton* {
							$DisplayVariable.IsChecked = [System.Convert]::ToBoolean($Value)
						}
						Default {
							$DisplayVariable.Text = $Value
						}
					}
				}

				$FoundSiteCode = (New-Object -ComObject Microsoft.SMS.Client -Strict -ErrorAction SilentlyContinue).GetAssignedSite()
				if (-not [System.String]::IsNullOrEmpty($FoundSiteCode)) {
					$WPFtextBoxSiteCode.Text = $FoundSiteCode
				}
				Update-GUI
			})

		$WPFbuttonSave.Add_Click( {
				$form.Cursor = "Wait"
				foreach ($key in $Global:XMLtoDisplayHash.Keys) {
					$DisplayVariable = Get-Variable $XMLtoDisplayHash[$key] -ValueOnly
					switch -wildcard ($XMLtoDisplayHash[$key]) {
						*toggleButton* {
							$Value = ($DisplayVariable.IsChecked).ToString()
						}
						Default {
							$Value = $DisplayVariable.Text
						}
					}
					$CMPackagerXML.PackagerPrefs.$key = [String]$Value
					Update-GUI
				}
				$CMPackagerXML.PackagerPrefs.LogPath = "$(Split-Path $WPFtextBoxWorkingDir.Text -Parent)\CMPackager.log"
				$CMPackagerXML.Save("$PSScriptRoot\CMPackager.prefs")
				$form.Cursor = "Arrow"
			})

		$Form.ShowDialog() | Out-Null
		exit
	}

	Add-LogContent "--- Starting CMPackager Version $($Global:ScriptVersion) ---" -Load
	Connect-ConfigMgr

	## Create the Temp Folder if needed
	Add-LogContent "Creating CMPackager Temp Folder"
	if (-not (Test-Path $Global:TempDir)) {
		New-Item -ItemType Container -Path "$Global:TempDir" -Force -ErrorAction SilentlyContinue
	}

	## Allow all Cookies to download (Prevents Script from Freezing)
	Add-LogContent "Allowing All Cookies to Download (This prevents the script from freezing on a download)"
	reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3" /t REG_DWORD /v 1A10 /f /d 0

	## Create Global Conditions as defined in GlobalConditions.xml
	$GlobalConditionsXML = (([xml](Get-Content "$ScriptRoot\GlobalConditions.xml")).GlobalConditions.GlobalCondition | Where-Object Name -NE "Template" )
	Foreach ($GlobalCondition in $GlobalConditionsXML) {
		$NewGCArguments = @{ }
		$GlobalCondition.ChildNodes | ForEach-Object { if ($_.Name -ne "GCType") { $NewGCArguments[$_.Name] = $_.'#text' } }
		Push-Location
		Set-Location $Global:CMSite
		if (-not (Get-CMGlobalCondition -Name $GlobalCondition.Name)) {
			switch ($GlobalCondition.GCType) {	
				WqlQuery { 
					Add-LogContent "Creating New WQL Global Condition"
					Add-LogContent "New-CMGlobalConditionWqlQuery $NewGCArguments"
					New-CMGlobalConditionWqlQuery @NewGCArguments
				}
				Script { 
					Add-LogContent "Creating New Script Global Condition"
					Add-LogContent "New-CMGlobalConditionScript $NewGCArguments"
					New-CMGlobalConditionScript @NewGCArguments
				}
				Default {
					Add-LogContent "ERROR: Please specify a valid Global Condition Type of either WqlQuery or Script"
				}
			}
		}
		Pop-Location
	}

	## Get the Recipes
	$RecipeList = Get-ChildItem $ScriptRoot\Recipes\ | Select-Object -Property Name -ExpandProperty Name | Where-Object -Property Name -NE "Template.xml" | Sort-Object -Property Name
	Add-LogContent -Content "All Recipes: $RecipeList"
	if (-not ([System.String]::IsNullOrEmpty($PSBoundParameters.SingleRecipe))) {
		$RecipeList = $RecipeList | Where-Object { $_ -eq $PSBoundParameters.SingleRecipe }
	}
	## Begin Looping through all the Recipes 
	ForEach ($Recipe In $RecipeList) {
		## Reset All Variables
		$Download = $false
		$ApplicationCreation = $false
		$DeploymentTypeCreation = $false
		$ApplicationDistribution = $false
		$ApplicationSupersedence = $false
		$ApplicationDeployment = $false
	
		## Import Recipe
		Add-LogContent "Importing Content for $Recipe"
		Write-Output "Begin Processing: $Recipe"
		[xml]$ApplicationRecipe = Get-Content "$PSScriptRoot\Recipes\$Recipe"
	
		## Perform Packaging Tasks
		Write-Output "Download"
		$Download = Start-ApplicationDownload -Recipe $ApplicationRecipe
		Add-LogContent "Continue to ApplicationCreation: $Download"
		If ($Download) {
			Write-output "Application Creation"
			$ApplicationCreation = Invoke-ApplicationCreation -Recipe $ApplicationRecipe
			Add-LogContent "Continue to DeploymentTypeCreation: $ApplicationCreation"
		}
		If ($ApplicationCreation) {
			Write-Output "Application Deployment Type Creation"
			$DeploymentTypeCreation = Add-DeploymentType -Recipe $ApplicationRecipe
			Add-LogContent "Continue to ApplicationDistribution: $DeploymentTypeCreation"
		}
		If ($DeploymentTypeCreation) {
			Write-Output "Application Distribution"
			$ApplicationDistribution = Invoke-ApplicationDistribution -Recipe $ApplicationRecipe
			Add-LogContent "Continue to ApplicationSupersedence: $ApplicationDistribution"
		}
		If ($ApplicationDistribution) {
			Write-Output "Application Supersedence"
			$ApplicationSupersedence = Invoke-ApplicationSupersedence -Recipe $ApplicationRecipe
			Add-LogContent "Continue to Application Deployment: $ApplicationSupersedence"
		}
		If ($ApplicationSupersedence) {
			Write-Output "Application Deployment"
			$ApplicationDeployment = Invoke-ApplicationDeployment -Recipe $ApplicationRecipe
			Add-logContent "Completed Processing of $Recipe"
		}
		if ($Global:TemplateApplicationCreatedFlag -eq $true) {
			Add-LogContent "WARN (LEGACY): The Requirements Application has been created, please do the following:`r`n1. Add an `"Install Behavior`" entry to the `"Templates`" deployment type of the $RequirementsTemplateAppName Application`r`n2. Run the CMPackager again to finish prerequisite setup and begin packaging software.`r`nExiting."
			Add-LogContent "THE REQUIREMENTS TEMPLATE APPLICTION IS NO LONGER NEEDED"
			Exit 0
		}
	}



	If ($Global:SendEmail -and $SendEmailPreference) {
		Send-EmailMessage
	}

	Add-LogContent "Cleaning Up Temp Directory $TempDir"
	Remove-Item -Path $TempDir -Recurse -Force

	## Reset all Cookies to download (Prevents Script from Freezing)
	Add-LogContent "Clearing All Cookies Download Setting"
	reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3" /v 1A10 /f

	Add-LogContent "--- End Of CMPackager ---"
}
