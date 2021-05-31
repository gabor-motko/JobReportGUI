Set-Location $PSScriptRoot
Write-Host "Hello!"

#region Load resources

# Provides access to the Windows Presentation Foundation framework for the GUI described in MainWindow.xaml
add-type -AssemblyName PresentationFramework

# Provides access to the Win32 interface. Its only purpose is to hide the console window.
add-type @"
using System;
using System.Runtime.InteropServices;
public class Win32
{
    [DllImport("Kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr ShowWindow(IntPtr hWnd, int nCmdShow);

    //[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    //public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool bRepaint);
    
    //[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    //public static extern IntPtr SetActiveWindow(IntPtr hWnd);

    public const int SW_HIDE = 0;
    public const int SW_MINIMIZE = 6;
    public const int SW_SHOWMINIMIZED = 2;
    public const int SW_RESTORE = 9;
}
"@

# Load the WPF definition of the main window
$window = [Windows.Markup.XamlReader]::Load([System.IO.File]::OpenRead([System.IO.Path]::Combine($PSScriptRoot, "MainWindow.xaml")))

# Load the config JSON file
$global:Config = Get-Content .\config.json | ConvertFrom-Json

#endregion

#region Set up WPF references
$loadJob = [PSCustomObject]@{
    LineSelect = $window.FindName("LoadJobLineSelect");
    LineSubmit = $window.FindName("LoadJobLineSubmit");
    List = $window.FindName("LoadJobList");
    CustomPattern = $window.FindName("LoadJobCustomPattern")
}

$locatePart = [PSCustomObject]@{
    SearchText = $window.FindName("LocatePartSearchText");
    Submit = $window.FindName("LocatePartSubmit");
    List = $window.FindName("LocatePartList");
    ContextMenu = [PSCustomObject]@{
        CopyPartNumber = $window.FindName("LocatePartCopyPartNumber")
    }
}

$trayParts = [PSCustomObject]@{
    List = $window.FindName("TrayPartList");
    ContextMenu = [PSCustomObject]@{
        CopyPartNumber = $window.FindName("TrayPartsCopyPartNumber")
    }
}

$jobInfoPanel = [PSCustomObject]@{
    PartNumber = $window.FindName("JobInfoPartNumber");
    Panelization = $window.FindName("JobInfoPanelization");
    Length = $window.FindName("JobInfoDimensionsLength");
    Width = $window.FindName("JobInfoDimensionsWidth");
    PlacementsTop = $window.FindName("JobInfoPlacementsTop");
    PlacementsBottom = $window.FindName("JobInfoPlacementsBottom");
    CycleTimeTop = $window.FindName("JobInfoCycleTimeTop");
    CycleTimeBottom = $window.FindName("JobInfoCycleTimeBottom")
}

$productImage = [PSCustomObject]@{
    UpdateButton = $window.FindName("ProductImageUpdateList");
    List = $window.FindName("ProductImageList");
    SearchText = $window.FindName("ProductImageSearchText");
    SearchCurrent = $window.FindName("ProductImageSearchCurrent")
}

$cartSetup = [PSCustomObject]@{
    Count11 = $window.FindName("CartSetupFeederCount11");
    Count21 = $window.FindName("CartSetupFeederCount21");
    Count31 = $window.FindName("CartSetupFeederCount31");
    Count12 = $window.FindName("CartSetupFeederCount12");
    Count22 = $window.FindName("CartSetupFeederCount22");
    Count32 = $window.FindName("CartSetupFeederCount32")
}

$statusText = $window.FindName("MainStatusText")
#endregion

#region Program logic

# Provides additional info about a Flexa product
class FlexaJobInfo
{
    [string] $Dimensions
    [int] $Panelization
    [int] $BottomPlacements
    [int] $TopPlacements
    [float] $BottomCycleTime
    [float] $TopCycleTime
    [string] $Rotation
}

# Describes a unique part (by PartNumber and Location) in the setup
class FlexaPart
{
    [string] $PartNumber
    [string] $Location
    [string] $Feeder
    [int] $Pitch
    [string] $Width
    [string] $Shape
    [string] $Package
    [int] $BottomQuantity
    [int] $TopQuantity
    #[string[]] $RefIDs
    [string[]] $BottomRefIDs
    [string[]] $TopRefIDs
}

# Describes a Flexa job
class FlexaJob
{
    [string] $PartNumber
    [FlexaPart[]] $Setup
    [FlexaJobInfo] $Info
}

# Uniquely identifies a Flexa job's resources to be requested from the Flexa server
class FlexaJobIdentifier
{
    [string] $Name
    [string] $Revision
    [string] $LineBottom
    [string] $LineTop
    [bool] $Active

    [bool] HasBottom()
    {
        return -not [string]::IsNullOrEmpty($this.LineBottom)
    }

    [bool] HasTop()
    {
        return -not [string]::IsNullOrEmpty($this.LineTop)
    }

    FlexaJobIdentifier([string] $n, [string] $r, [bool] $b, [bool] $t)
    {
        $this.Name = $n
        $this.Revision = $r
        $this.HasBottom = $b
        $this.HasTop = $t
    }

    # Creates a FlexaJobIdentifier instance from the JSON data received from the Flexa server
    FlexaJobIdentifier($json)
    {
        # TODO: validate JSON schema

        $this.Name = $json.Name
        $this.Revision = $json.Revision
        $this.LineBottom = $json.BLine
        $this.LineTop = $json.TLine
    }
}

class ProductImageIdentifier
{
    # TODO: parsing the product's PartNumber and revision from the directory name string
    # is possible, but changing the product naming schema or introducing an edge case that
    # invalidates the regex pattern will cause issues.

    [string] $Name  # The directory name, which contains the desired SmallTop.jpg file
    [string] $Type  # Normal, Nitrogen, or Obsolete. This is a 1:1 dependence on the parent directory and should maybe not be noted?
    [string] $FilePath  # The full path to the desired image file
    [string] $PartNumber

    ProductImageIdentifier($n, $t, $p)
    {
        $this.Name = $n
        $this.Type = $t
        $this.FilePath = $p
        [System.Text.RegularExpressions.Match] $match = [System.Text.RegularExpressions.Regex]::Match($n, "($($global:config.PartNumberPattern))")
        $this.PartNumber = $match.Groups[1].Value
    }
}

[FlexaJob] $global:CurrentJob = $null
[ProductImageIdentifier[]] $global:ProductImages = $null

# Set the status text block
function Set-Status
{
    param(
        [Parameter(Position=0)]
        [string] $Message,
        [int] $Progress,
        [switch] $NoConsoleOutput = $false,
        [switch] $NoNewline = $false
    )
    $statusText.Text = $Message
    if(-not $NoConsoleOutput)
    {
        if($NoNewline) { Write-Host $Message -NoNewline }
        else { Write-Host $Message }
    }
}

# Shorthand function to explicitly pass Accept-Language header to Invoke-WebRequest.
function Get-HttpResponse
{
    # This is only to prevent a bug on the server side where having hu-HU in the Accept-Language
    # header causes the software to parse decimal values using the incorrect culture info (hu-HU
    # uses decimal comma instead of decimal point). TODO: report issue to Janos Gyuro and/or Fuji.
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [string]$Uri
    )
    Invoke-WebRequest -Uri $Uri -Headers @{"Accept-Language" = "en-US;q=0.7,en;q=0.3"}
}

# Returns true if both FlexaJobs have the same PartNumber and Location
function Compare-FlexaPart
{
    param($a, $b)
    return ($a.PartNumber -eq $b.PartNumber) -and ($a.Location -eq $b.Location)
}

# Return the values of a hashtable as an array
function Get-ArrayFromHashtableValues
{
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [Hashtable]$Table
    )
    foreach($key in $Table.Keys)
    {
        $Table[$key]
    }
}

function Get-FlexaSetup
{
    param([string]$Name, [string]$Revision, [string]$Side, [FlexaJobInfo]$Info)
    $setup = @{}
    
    # Use HttpUtility.UrlEncode for string parameters
    $url = "http://$($global:Config.FlexaServer)/fujiweb/fujimoni/ui/jobreport.aspx?Job=$([System.Web.HttpUtility]::UrlEncode($Name))&Revision=$([System.Web.HttpUtility]::UrlEncode($Revision))&Side=$Side"
    $response = Get-HttpResponse -uri $url
    $document = $response.ParsedHtml

    # If the #PartTable element doesn't exist, then the specified job (side) exists, but empty.
    if($null -eq $document) {return @{}}
    $partTableElement = $document.getElementByID("PartTable")
    if($null -eq $partTableElement){return @{}}

    # The report contains multiple tables with the class name FeederSetup. Each one represents the setup of a particular machine type (important on SMT04), take the union of these.
    foreach($table in $document.getElementsByClassName("FeederSetup"))
    {
        $rows = $table.getElementsByTagName("tr")
        foreach($row in ($rows | Select-Object -skip 1)) # skip the table header row
        {
            $fields = $row.getElementsByTagName("td")

            $pn = if($null -ne $fields[1].innerText) {$fields[1].innerText} else {$fields[2].innerText} # handle cases where PN is null, e.g. KTCMA-CONVEYOR

            $part = New-Object FlexaPart
            $part.Location = $fields[0].innerText
            $part.PartNumber = $pn
            $part.Feeder = $fields[2].innerText
            $part.Width = $fields[3].innerText
            $part.Pitch = $fields[4].innerText
            if($Side -ilike "B")
            {
                $part.BottomQuantity = [int]($fields[5].innerText)
                $part.BottomRefIDs = -split $fields[6].innerText
            }
            elseif($Side -ilike "T")
            {
                $part.TopQuantity = [int]($fields[5].innerText)
                $part.TopRefIDs = -split $fields[6].innerText
            }
            $part.Package = ""
            $part.Shape = ""

            $setup.Add($pn, $part)
        }
    }
    foreach($row in ($partTableElement.getElementsByTagName("tr") | select-object -skip 1))
    {
        $fields = $row.getElementsByTagName("td");
        $setup[$fields[0].innerText].Package = $fields[1].innerText;
        $setup[$fields[0].innerText].Shape= $fields[2].innerText;
    }
    # Read the job info values
    $Info.Dimensions = $document.GetElementByID("LabelSize").innerText
    $Info.Panelization = $document.GetElementByID("LabelBoard").innerText
    $Info.Rotation = $document.GetElementByID("LabelPanelRotation").innerText
    if($Side -ilike "T")
    {
        $Info.TopCycleTime = $document.GetElementByID("LabelCycleTime").innerText
    }
    else
    {
        $Info.BottomCycleTime = $document.GetElementByID("LabelCycleTime").innerText
    }

    Get-ArrayFromHashtableValues $setup
}

# Download the HTML documents for both sides and parse the relevant info
function Get-FlexaReport
{
    param([FlexaJobIdentifier] $Identifier)
    $bottom = @()
    $top = @()
    $info = [FlexaJobInfo]::new()
    
    # Get Bottom
    if($Identifier.HasBottom()) {
        Set-Status "Downloading $($Identifier.Name) $($Identifier.Revision) B..."
        $bottom = Get-FlexaSetup -Name $($Identifier.Name) -Revision $($Identifier.Revision) -Side "B" -Info $info
    }

    # Get Top
    if($Identifier.HasTop()) {
        Set-Status "Downloading $($Identifier.Name) $($Identifier.Revision) T..."
        $top = Get-FlexaSetup -Name $($Identifier.Name) -Revision $($Identifier.Revision) -Side "T" -Info $info
    }

    # Fill in NULL fields from the other side
    Set-Status "Combining NULL fields..."
    foreach($part in $bottom)
    {
        $other = $top | Where-Object PartNumber -ilike $part.PartNumber | Select-Object -First 1
        if([System.String]::IsNullOrEmpty($part.Package))
        {
            $part.Package = $other.Package;
            $part.Shape = $other.Shape;
        }
    }

    foreach($part in $top)
    {
        $other = $bottom | Where-Object PartNumber -ilike $part.PartNumber | Select-Object -First 1
        if([System.String]::IsNullOrEmpty($part.Package))
        {
            $part.Package = $other.Package;
            $part.Shape = $other.Shape;
        }
    }

    # Merge the two tables on PartNumber and Location
    Set-Status "Merging tables..."
    $union = $bottom.Clone();
    foreach($part in $top)
    {
        # If there exists an element in the union where both PartNumber and Location are equal to $part, extend it.
        # If either of those properties is different, add a new entry.
        $other = $union | Where-Object {Compare-FlexaPart $_ $part} | Select-Object -First 1
        if($null -eq $other)
        {
            $union += $part
        }
        else 
        {
            $other.TopQuantity += $part.TopQuantity
            $other.TopRefIDs = ($other.TopRefIDs + $part.TopRefIDs) | Where-Object {$_ -ne ""} | Sort-Object
        }
    }
    $report = New-Object FlexaJob
    $report.Setup = $union
    $report.Info = $info

    $info.BottomPlacements = ($report.Setup | Measure-Object -Property BottomQuantity -Sum).Sum
    $info.TopPlacements = ($report.Setup | Measure-Object -Property TopQuantity -Sum).Sum
    return $report
}

# Return an array of Flexa jobs
function Get-FlexaJobList
{
    param(
        [string]$DirectoryPattern = ""
    )
    write-host "Downloading list for pattern: $DirectoryPattern"
    # Get the Flexa directory names
    $groups = ((Get-HttpResponse -uri "http://$($global:Config.FlexaServer)/fujiweb/fujimoni/ui/API/JobList?Method=EUI_TreeGrid").Content | convertfrom-json).children | Select-Object Name;

    # Get Flexa job data from directory names that match the provided pattern
    foreach($group in ($groups | Where-Object Name -match $DirectoryPattern))
    {
        $name = $group.Name;
        $response = Get-HttpResponse -uri "http://$($global:Config.FlexaServer)/fujiweb/fujimoni/ui/API/JobList?Method=EUI_DataGrid&Group=$name&page=1&rows=65536";
        foreach($job in (($response.Content | ConvertFrom-Json).rows))
        {
            # Return an array of matching job info
            #[PSCustomObject]@{Name = $job.Name; Revision = $job.Revision; LineBottom = $job.BLine; LineTop = $job.TLine};
            #$id = New-Object FlexaJobIdentifier -ArgumentList $job
            [FlexaJobIdentifier]::new($job)
        }
    }
}

#endregion

#region Initialize

# Populate the line selection combobox
foreach($line in $global:Config.Lines)
{
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $line.Name
    $item.Tag = $line.Pattern
    $loadJob.LineSelect.AddChild($item)
}
$loadJob.LineSelect.SelectedIndex = 0

#endregion

#region Event handlers

# Scriptblock that is executed when a job is loaded
$loadJobCallback = {
	$job = ([System.Windows.Controls.ListView]$args[0]).SelectedItem
    if($null -eq $job)
    {
        Set-Status "Job not selected."
        return
    }
    Set-Status "Loading $($job.Name) ($($job.Revision))..."
    $global:CurrentJob = Get-FlexaReport -Identifier $job
    $trayParts.List.ItemsSource = @() + ($global:CurrentJob.Setup | Where-Object Location -imatch $global:Config.TrayLocationPattern)

    $size = $global:CurrentJob.Info.Dimensions -split "x"
    $length = $size[0].Trim()
    $width = $size[1].Trim()
    $jobInfoPanel.Length.Text = $size[0].Trim()
    $jobInfoPanel.Width.Text = $size[1].Trim()

    $jobInfoPanel.Panelization.Text = $global:CurrentJob.Info.Panelization
    $match = [System.Text.RegularExpressions.Regex]::Match($job.Name, "($($global:Config.PartNumberPattern))")
    $global:CurrentJob.PartNumber = $match.Groups[1].Value
    $jobInfoPanel.PartNumber.Text = $match.Groups[1].Value
    $window.Title = $match.Groups[1].Value + " :: Job Report"
    $jobInfoPanel.PlacementsBottom.Text = $global:CurrentJob.Info.BottomPlacements
    $jobInfoPanel.PlacementsTop.Text = $global:CurrentJob.Info.TopPlacements
    $jobInfoPanel.CycleTimeBottom.Text = $global:CurrentJob.Info.BottomCycleTime
    $jobInfoPanel.CycleTimeTop.Text = $global:CurrentJob.Info.TopCycleTime
    
    $cartSetup.Count11.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M11) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count
    $cartSetup.Count21.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M21) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count
    $cartSetup.Count31.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M31) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count
    $cartSetup.Count12.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M12) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count
    $cartSetup.Count22.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M22) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count
    $cartSetup.Count32.Text = ($global:CurrentJob.Setup | Where-Object {($_.Location -imatch $global:Config.FeederLocationPatterns.M32) -and (-not ($global:Config.InvalidFeeders -contains $_.Feeder)) } | Measure-Object).Count

    Set-Status "Report loaded!"
    & $locatePartCallback
}

# Scriptblock that is executed when the list should be updated
$locatePartCallback = {
    $pattern = $locatePart.SearchText.Text
    $items = $global:CurrentJob.Setup | Where-Object {($_.PartNumber -imatch "^$pattern") -or (($_.BottomRefIDs -match $pattern) -gt 0) -or (($_.TopRefIDs -match $pattern) -gt 0)}
    $locatePart.List.ItemsSource = @() + $items
}

# Scriptblock that is executed when the list is double-clicked
$partInfoCallback = {
    [FlexaPart] $part = ([System.Windows.Controls.ListView] $args[0]).SelectedItem
    if($null -eq $part)
    {
        Set-Status "Part not selected."
        return
    }

    $sb = [System.Text.StringBuilder]::new()

    if($part.BottomQuantity + $part.TopQuantity -ne 0)
    { 
        if(-not [string]::IsNullOrEmpty($part.Feeder))
        {
            $sb.AppendLine("`nFeeder size: $($part.Width.Remove($part.Width.Length - 2, 2)) x $($part.Pitch)`nFeeder: $($part.Feeder)")
        }
        $sb.AppendLine("`nPackage: $($part.Package)")
        $sb.AppendLine("Shape: $($part.Shape)")
        $sb.AppendLine("`nBottom quantity: $($part.BottomQuantity)")
        $sb.AppendLine("Bottom RefIDs: $($part.BottomRefIDs -join ", ")")
        $sb.AppendLine("`nTop quantity: $($part.TopQuantity)")
        $sb.AppendLine("Top RefIDs: $($part.TopRefIDs -join ", ")")
    }
    else
    {
        $sb.AppendLine("This part is present in the setup, but not used in the job.")
    }

    [System.Windows.MessageBox]::Show($sb.ToString(), $part.PartNumber)
}

$copyPartNumberCallback = {
    # If a selected item exists in the sender, put its PartNumber on the clipboard
    [FlexaPart] $part = ([System.Windows.Controls.ListView] $args[0].Parent.PlacementTarget).SelectedItem
    if($null -ne $part -and (-not [string]::IsNullOrEmpty($part.PartNumber)))
    {
        $part.PartNumber | Set-Clipboard
    }
}

# Scriptblock that is executed when the product image list should be updated.
$loadProductImageListCallback = {
    $dirs = [System.Collections.ArrayList]::new()
    foreach($parent in $global:Config.MirtecImagePaths)
    {
        $children = Get-ChildItem -Path $parent.Path -Directory
        foreach($child in $children)
        {
            $dirs.Add([ProductImageIdentifier]::new($child.Name, $parent.Type, (Join-Path (Join-Path $parent.Path $child) $global:Config.MirtecImageSuffix)))
        }
    }
    $global:ProductImages = $dirs.ToArray()
}

$openProductImageCallback = {
    #[system.windows.messagebox]::Show($productImage.List.SelectedItem.Name)
    # TODO: open as read-only, or copy to temporary file
    Invoke-Item $productImage.List.SelectedItem.FilePath
}

$productImageSearchCallback = {
    try
    {
        $productImage.List.ItemsSource = @() + ($global:ProductImages | Where-Object Name -match $productImage.SearchText.Text)
    }
    catch [System.Management.Automation.PSArgumentException]
    {
        [System.Windows.MessageBox]::Show("A keresett kifejezés érvénytelen karaktereket tartalmaz.`n`nLásd a HASZNÁLAT dokumentum Hibakeresés > Regex hiba részét!")
    }
}

# Add event handlers
$window.Add_Loaded({
    $window.Activate()
})

$loadJob.LineSubmit.Add_Click({
    Set-Status "Loading..."
    $pattern = [string] $loadJob.LineSelect.SelectedItem.Tag
    if([string]::IsNullOrEmpty($pattern))
    {
        $pattern = $loadJob.CustomPattern.Text;
    }
    $jobs = Get-FlexaJobList -DirectoryPattern $pattern | Sort-Object Name
	$loadJob.List.ItemsSource = @() + $jobs
	Set-Status "Loaded $($jobs.Count) jobs."
})

$loadJob.List.Add_MouseDoubleClick($loadJobCallback)

$locatePart.Submit.Add_Click($locatePartCallback)
$locatePart.SearchText.Add_TextChanged($locatePartCallback)
$locatePart.List.Add_MouseDoubleClick($partInfoCallback)

$locatePart.ContextMenu.CopyPartNumber.Add_Click($copyPartNumberCallback)
$trayParts.ContextMenu.CopyPartNumber.Add_Click($copyPartNumberCallback)
$trayParts.List.Add_MouseDoubleClick($partInfoCallback)

$productImage.SearchCurrent.Add_Click({
    if($null -eq $global:ProductImages)
    {
        & $loadProductImageListCallback
    }
    $productImage.SearchText.Text = $global:CurrentJob.PartNumber
})

$productImage.UpdateButton.Add_Click({
    & $loadProductImageListCallback
    & $productImageSearchCallback
})
$productImage.List.Add_MouseDoubleClick($openProductImageCallback)
$productImage.SearchText.Add_TextChanged($productImageSearchCallback)

#endregion  

$console = [Win32]::GetConsoleWindow()
if($console -ne [IntPtr]::Zero)
{
    $null = [Win32]::ShowWindow($console, [Win32]::SW_MINIMIZE)
    #$windowHandle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
    #[Win32]::MoveWindow($console, [int]($window.Left + $window.ActualWidth), $window.Top, 300, $window.ActualHeight, $false)
}

# NOTE: This call blocks the thread until the window is closed. ANY return value including error should unhide the console window.
$null = $window.ShowDialog()

if($console -ne [IntPtr]::Zero)
{
    $null = [Win32]::ShowWindow($console, [Win32]::SW_RESTORE)
}

Write-Host "Bye!"