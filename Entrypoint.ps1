# TODO: Remove and make it automatically
param (
    [Parameter(Mandatory)]
    [ValidateSet('Issue', 'PR', 'Push', '__TESTS__', 'Scheduled')]
    [String] $Type
)

#region Variables pool
$EVENT_RAW = Get-Content $env:GITHUB_EVENT_PATH -Raw
# Convert actual API response to object
$EVENT = ConvertFrom-Json $EVENT_RAW
# Event type for automatic handler detection
$EVENT_TYPE = $env:GITHUB_EVENT_NAME
# user/repo format
$REPOSITORY = $env:GITHUB_REPOSITORY
# Location of bucket
$BUCKET_ROOT = $env:GITHUB_WORKSPACE

# Backward compatability for manifests inside root of repository
$nestedBucket = Join-Path $BUCKET_ROOT 'bucket'
$MANIFESTS_LOCATION = if (Test-Path $nestedBucket) { $nestedBucket } else { $BUCKET_ROOT }

$NON_ZERO_EXIT = $false
#endregion Variables pool

#region Function pool
#region ⬆⬆⬆⬆⬆⬆⬆⬆ OK ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆
function Write-Log {
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    param ([String[]] $Message)

    Write-Output ''
    $Message | ForEach-Object { Write-Output "LOG: $_" }
}

function Get-EnvironmentVariables {
    return Get-ChildItem Env: | Where-Object { $_.Name -ne 'GITHUB_TOKEN' }
}

function Initialize-NeededSettings {
    New-Item '/root/scoop/cache', '/github/home/scoop/cache' -Force -ItemType Directory | Out-Null
    git config --global user.name ($env:GITHUB_REPOSITORY -split '/')[0]
    if (-not ($env:GITH_EMAIL)) {
        Write-Log 'Pushing is not possible without email environment'
    } else {
        git config --global user.email $env:GITH_EMAIL
    }

    Write-Log (Get-EnvironmentVariables | ForEach-Object { "$($_.Key) | $($_.Value)" })
}

function Resolve-IssueTitle {
    <#
    .SYNOPSIS
        Parse issue title and return manifest name, version and problem.
    .PARAMETER Title
        Title to be parsed.
    .EXAMPLE
        Resolve-IssueTitle 'recuva@2.4: hash check failed'
    #>
    param([String] $Title)

    $result = $Title -match '(?<name>.+)@(?<version>.+):\s*(?<problem>.*)$'

    if ($result) {
        return $Matches.name, $Matches.version, $Matches.problem
    } else {
        return $null, $null, $null
    }
}

function New-Array {
    <#
    .SYNOPSIS
        Return new array list for better operations.
    #>

    return New-Object System.Collections.ArrayList
}

function New-CheckListItem {
    <#
    .SYNOPSIS
        Helper functino for creating markdown check lists.
    .PARAMETER Check
        Name of check.
    .PARAMETER OK
        Check was met.
    #>
    param ([String] $Check, [Switch] $OK)

    if ($OK) {
        return "- [x] $Check"
    } else {
        return "- [ ] $Check"
    }
}

function Invoke-GithubRequest {
    <#
    .SYNOPSIS
        Invoke authenticated github API request.
    .PARAMETER Query
        Query to be executed.
    .PARAMETER Method
        Method to be used with request
    .PARAMETER Body
        Additional body to be send.
    #>
    param(
        [Parameter(Mandatory)]
        [String] $Query,
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = 'Get',
        [Hashtable] $Body
    )

    $api_base_url = 'https://api.github.com'
    $headers = @{
        # Authorization token is neeeded for posting comments and to increase limit of requests
        'Authorization' = "token $env:GITHUB_TOKEN"
    }
    $parameters = @{
        'Headers' = $headers
        'Method'  = $Method
        'Uri'     = "$api_base_url/$Query"
    }

    Write-Debug $parameters.Uri

    if ($Body) { $parameters.Add('Body', (ConvertTo-Json $Body -Depth 8 -Compress)) }

    return Invoke-WebRequest @parameters
}

function Add-Comment {
    <#
    .SYNOPSIS
        Add comment into specific issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    .PARAMETER Message
        String or array of string to be send as comment.
    #>
    param(
        [Int] $ID,
        [Alias('Comment')]
        [String[]] $Message
    )

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID/comments" -Method Post -Body @{ 'body' = ($Message -join "`r`n") }
}

function Add-Label {
    <#
    .SYNOPSIS
        Add label to issue / PR.
    .PARAMETER ID
        Id of issue / PR.
    .PARAMETER Label
        Label to be set.
    #>
    param([Int] $ID, [String[]] $Label)

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID/labels" -Method Post -Body @{ 'labels' = $Label }
}

function Get-AllChangedFilesInPR {
    <#
    .SYNOPSIS
        Get list of all changed files inside pull request.
    .PARAMETER ID
        ID of pull request.
    .PARAMETER Filter
        Return only files which are not 'removed'
    #>
    param([Int] $ID, [Switch] $Filter)

    $files = (Invoke-GithubRequest -Query "repos/$REPOSITORY/pulls/$ID/files").Content | ConvertFrom-Json
    if ($Filter) { $files = $files | Where-Object { $_.status -ne 'removed' } }

    return $files | Select-Object -Property filename, status
}

function Close-Issue {
    <#
    .SYNOPSIS
        Close issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    #>
    param([Int] $ID)

    return Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID" -Method Patch -Body @{ 'state' = 'closed' }
}

function Remove-Label {
    <#
    .SYNOPSIS
        Remove label from issue / PR.
    .PARAMETER ID
        ID of issue / PR.
    .PARAMETER Label
        Array of labels to be removed.
    #>
    param([Int] $ID, [String[]] $Label)

    $responses = @()
    foreach ($lab in $Label) {
        # TODO: Check existence
        $responses += Invoke-GithubRequest -Query "repos/$REPOSITORY/issues/$ID/labels/$label" -Method Delete
    }

    return $responses
}

function Test-Hash {
    param (
        [Parameter(Mandatory = $true)]
        [String] $Manifest,
        [Int] $IssueID
    )

    & "$env:SCOOP_HOME\bin\checkhashes.ps1" -App $Manifest -Dir $MANIFESTS_LOCATION -Update
    # TODO: Resolve eror state handling from withing binary
    # https://github.com/Ash258/GithubActionsBucketForTesting/runs/153999789

    $status = hub status --porcelain -uno
    Write-Log "Status: $status"

    $changes = hub diff --name-only
    if (($changes).Count -eq 1) {
        Write-Log 'Verified hash failed'

        $message = @('You are right. Thanks for reporting.')
        $prs = (Invoke-GithubRequest "repos/$REPOSITORY/pulls?state=open&base=master&sorting=updated").Content | ConvertFrom-Json
        $prs = $prs | Where-Object { $_.title -ceq "${Manifest}: Hash fix" }

        # There is alreay PR for
        if ($prs.Count -gt 0) {
            Write-Log 'PR - Update description'

            # Only take latest updated
            $pr = $prs | Select-Object  -First 1
            $prID = $pr.number
            $prBody = $pr.Body
            # TODO: Additional checks if this PR is really fixing same issue

            $message += ''
            $message += "There is already pull request to fix this issue. (#$prID)"

            Write-Log $prID
            # Update PR description
            Invoke-GithubRequest "repos/$REPOSITORY/pulls/$prID" -Method Patch -Body @{ "body" = (@("- Closes #$IssueID", $prBody) -join "`r`n") }
        } else {
            Write-Log 'PR - Create new branch and pst PR'

            $branch = "$manifest-hash-fix-$(Get-Random -Maximum 258258258)"
            hub checkout -B $branch

            hub add $changes
            hub commit -m "${Manifest}: hash fix"
            hub push origin $branch

            # Create new PR
            Invoke-GithubRequest -Query "repos/$REPOSITORY/pulls" -Method Post -Body @{
                'title' = "${Manifest}: Hash fix"
                'base'  = 'master'
                'head'  = $branch
                'body'  = "- Closes #$IssueID"
            }
        }

        Add-Label -ID $IssueID -Label 'verified', 'hash-fix-needed'
        Add-Comment -ID $IssueID -Message $message
    } else {
        Write-Log 'Cannot reproduce'

        Add-Comment -ID $IssueID -Message @(
            'Cannot reproduce',
            '',
            "Are you sure your scoop is up to date? Please run ``scoop update; scoop uninstall $Manifest; scoop install $Manifest``"
        )
        Remove-Label -ID $IssueID -Label 'hash-fix-needed'
        Close-Issue -ID $IssueID
    }
}

function New-DetailsCommentString {
    <#
    .SYNOPSIS
        Create string surrounded with <details>.
    .PARAMETER Summary
        What should be displayed on button.
    .PARAMETER Content
        Content of details block.
    .PARAMETER Type
        Type of code fenced block (example `json`, `yml`, ...).
        Needs to be valid markdown code fenced block type.
    #>
    param([String] $Summary, [String[]] $Content, [String] $Type = 'text')

    return @"
<details>
    <summary>$Summary</summary>

``````$Type
$($Content -join "`r`n")
</details>
``````
"@
}

function Test-Downloading {
    param([String] $Manifest, [Int] $IssueID)

    $manifest_path = Get-Childitem $MANIFESTS_LOCATION "$Manifest\.*" | Select-Object -First 1 -ExpandProperty Fullname
    $manifest_o = Get-Content $manifest_path -Raw | ConvertFrom-Json

    $broken_urls = @()
    foreach ($arch in @('64bit', '32bit')) {
        $urls = @(url $manifest_o $arch)

        foreach ($url in $urls) {
            Write-Log "$url"

            try {
                dl_with_cache $Manifest 'DL' $url "/$fname" $manifest_o.cookies $true
            } catch {
                $broken_urls += $url
                continue
            }
        }
    }

    if ($broken_urls.Count -eq 0) {
        Write-Log 'All OK'

        Add-Comment -ID $IssueID -Comment 'Cannot reproduce.', '', 'All files can be downloaded properly (Please keep in mind I can only download files without aria2 support (yet))'
        # TODO: Close??
    } else {
        Write-Log @('Broken URLS:', $broken_urls)

        $string = ($broken_urls | ForEach-Object { "- $_" }) -join "`r`n"
        Add-Label -ID $IssueID -Label 'package-fix-needed', 'verified', 'help-wanted'
        Add-Comment -ID $IssueID -Comment 'Thanks for reporting. You are right. Following URLs are not accessible:', '', $string
    }
}

function Initialize-Scheduled {
    <#
    .SYNOPSIS
        Excavator alternative. Based on schedule execute auto-pr function.
    #>
    Write-Log 'Scheduled initialized'

    $params = @{
        'Dir'      = $MANIFESTS_LOCATION
        'Upstream' = "${REPOSITORY}:master"
        'Push'     = $true
    }
    if ($env:SPECIAL_SNOWFLAKES) { $params.Add('SpecialSnowflakes', ($env:SPECIAL_SNOWFLAKES -split ',')) }

    & "$env:SCOOP_HOME\bin\auto-pr.ps1" @params
    # TODO: Post some comment??

    Write-Log 'Auto pr - DONE'
}

function Initialize-PR {
    <#
    .SYNOPSIS
        Handle pull requests actions.
    #>
    Write-Log 'PR initialized'

    if ($EVENT.actions -ne 'opened') {
        Write-Log 'Only action ''opened'' is supported'
        exit 0
    }

    Write-log 'Files in PR:'
    Get-ChildItem $BUCKET_ROOT
    Get-ChildItem $MANIFESTS_LOCATION

    $prID = $EVENT.number
    # Do not run on removed files
    $files = Get-AllChangedFilesInPR $prID -Filter
    # $message = @()
    $checks = @()

    foreach ($file in $files) {
        Write-Log "Starting $($file.filename) checks"

        # Convert path into gci item to hold all needed information
        # TODO: Resolve root of PR
        $manifest = Get-ChildItem $BUCKET_ROOT $file.filename
        $object = Get-Content $manifest -Raw | ConvertFrom-Json
        $statuses = [Ordered] @{ }

        #region Property checks
        $statuses.Add('Description', ([bool] $object.description))
        $statuses.Add('License', ([bool] $object.license))
        #endregion Property checks

        #region Hashes
        Write-Log 'Hashes'

        $outputH = @(& "$env:SCOOP_HOME\bin\checkhashes.ps1" -App $manifest.Basename -Dir $MANIFESTS_LOCATION *>&1)
        Write-Log $outputH

        # everything should be all right when latest string in array will be OK
        $statuses.Add('Hashes', ($outputH[-1] -like 'OK'))

        Write-Log 'Hashes done'
        #endregion Hashes

        #region Checkver
        Write-Log 'Checkver'
        # TODO: Autoupdate
        $outputV = @(& "$env:SCOOP_HOME\bin\checkver.ps1" -App $manifest.Basename -Dir $MANIFESTS_LOCATION -Force *>&1)
        Write-log $outputV

        # If there are more than 2 lines and second line is not version, there is problem
        $statuses.Add('Checkver', ((($outputV.Count -ge 2) -and ($outputV[1] -like "$($object.version)"))))
        $statuses.Add('Autoupdate', ($outputV[-1] -notlike 'ERROR*'))

        Write-Log 'Checkver done'
        #endregion

        #region formatjson
        Write-Log 'Format'
        # TODO:
        Write-Log 'Format done'
        #endregion formatjson

        $checks += [Ordered] @{ 'Name' = $manifest.Basename; 'Statuses' = $statuses }

        Write-Log "Finished $($file.filename) checks"
    }

    # Create nice comment to post
    $message = New-Array
    foreach ($check in $checks) {
        $message.Add("### $($check.Name)")
        $message.Add('')
        foreach ($status in $check.Statuses.Keys) {
            $b = $check.Statuses.Item($status)
            Write-Log "$status | $b"

            if (-not $b) { $env:NON_ZERO_EXIT = $true }

            $message.Add((New-CheckListItem $status -OK:$b))
        }
        $message.Add('')
    }

    # Add some more human friendly message
    $message.Insert(0, 'Thanks for contributing.')
    if ($env:NON_ZERO_EXIT) {
        $message.Insert(1, 'Your changes does not pass some checks')
    } else {
        $message.InsertRange(1, @('All changes looks good.', '', 'Wait for review from human collaborators.'))
    }

    Add-Comment -ID $prID -Message $message

    Write-Log 'PR action finished'
}

#endregion ⬆⬆⬆⬆⬆⬆⬆⬆ OK ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆














function Test-ExtractDir {
    param([String] $Manifest, [Int] $IssueID)

    # Load manifest
    $manifest_path = Get-Childitem $MANIFESTS_LOCATION "$Manifest\.*" | Select-Object -First 1 -ExpandProperty Fullname
    $manifest_o = Get-Content $manifest_path -Raw | ConvertFrom-Json

    $message = @()
    $failed = $false
    $version = 'EXTRACT_DIR'

    foreach ($arch in @('64bit', '32bit')) {
        $urls = @(url $manifest_o $arch)
        $extract_dirs = @(extract_dir $manifest_o $arch)

        Write-Log $urls
        Write-Log $extract_dirs

        for ($i = 0; $i -lt $urls.Count; ++$i) {
            $url = $urls[$i]
            $dir = $extract_dirs[$i]
            dl_with_cache $Manifest $version $url $null $manifest_o.cookie $true

            $cached = cache_path $Manifest $version $url | Resolve-Path | Select-Object -ExpandProperty Path
            Write-Log "FILEPATH $url, ${arch}: $cached"

            $full_output = @(7z l $cached | awk '{ print $3, $6 }' | grep '^D')
            $output = @(7z l $cached -ir!"$dir" | awk '{ print $3, $6 }' | grep '^D')

            $infoLine = $output | Select-Object -Last 1
            $status = $infoLine -match '(?<files>\d+)\s+files(,\s+(?<folders>\d+)\s+folders)?'
            if ($status) {
                $files = $Matches.files
                $folders = $Matches.folders
            }

            # There are no files and folders like
            if ($files -eq 0 -and (!$folders -or $folders -eq 0)) {
                Write-Log "No $dir in $url"

                $failed = $true
                $message += New-DetailsCommentString -Summary "Content of $arch $url" -Content $full_output
                Write-Log "$dir, $arch, $url FAILED"
            } else {
                Write-Log "Cannot reproduce $arch $url"

                Write-Log "$arch ${url}:"
                Write-Log $full_output
                Write-Log "$dir, $arch, $url OK"
            }
        }
    }

    if ($failed) {
        Write-Log 'Failed' $failed
        $message = "You are right. Can reproduce", '', $message
        Add-Label -ID $IssueID -Label 'verified', 'package-fix-needed', 'help-wanted'
    } else {
        Write-Log 'Everything all right' $failed
        $message = "Cannot reproduce. Are you sure your scoop is updated? Try to run ``scoop update; scoop uninstall $Manifest; scoop install $Manifest``"
        $message += ''
        $message += 'See action log for more info'
    }

    Add-Comment -ID $IssueID -Message $message
}

# Need to mock function from core
function global:Get-AppFilePath {
    param ([String] $App = 'Aria2', [String] $File = 'aria2c')

    return which $File
}

function Initialize-Issue {
    Write-Log 'Issue initialized'

    Write-log "ACTION: $($EVENT.action)"

    if ($EVENT.action -ne 'opened') {
        Write-Log "Only action 'opened' is supported."
        exit 0
    }

    $title = $EVENT.issue.title
    $id = $EVENT.issue.number

    $problematicName, $problematicVersion, $problem = Resolve-IssueTitle $title
    if (($null -eq $problematicName) -or
        ($null -eq $problematicVersion) -or
        ($null -eq $problem)
    ) {
        Write-Log 'Not compatible issue title'
        exit 0
    }

    switch -Wildcard ($problem) {
        '*hash check*' {
            Write-Log 'Hash check failed'
            Test-Hash $problematicName $id
        }
        '*extract_dir*' {
            Write-Log 'Extract dir error'
            # TODO:
            # Test-ExtractDir $problematicName $id
        }
        '*download*failed*' {
            Write-Log 'Download failed'
            Test-Downloading $problematicName $id
        }
    }
}

function Initialize-Push {
    Write-Log 'Push initialized'
}
#endregion Function pool

#region Main
# For dot sourcing whole file inside tests
if ($Type -eq '__TESTS__') { return }

Initialize-NeededSettings

# Load all scoop's modules.
# Dot sourcing needs to be done on highest scope possible to propagate into lower scopes
Write-Log 'Importing all modules'
Get-ChildItem "$env:SCOOP_HOME\lib" '*.ps1' | Select-Object -ExpandProperty Fullname | ForEach-Object { . $_ }

switch ($Type) {
    'Issue' { Initialize-Issue }
    'PR' { Initialize-PR }
    'Push' { Initialize-Push }
    'Scheduled' { Initialize-Scheduled }
}

# TODO: Remove after all events are captured and saved and before release
Write-Log 'FULL EVENT TO BE SAVED'

$EVENT_RAW

# TODO: Uncomment correct one
switch ($EVENT_TYPE) {
    'issues' { Write-Log 'In future there will be issue handler initialized' }
    'pull_requests' { Write-Log 'In future there will be PR handler initialized' }
    'push' { Write-Log 'In future there will be push handler initialized' }
    'schedule' { Write-Log 'In future there will be schedule handler initialized' }
    # 'issues' { Initialize-Issue }
    # 'pull_requests' { Initialize-PR }
    # 'push' { Initialize-Push }
    # 'schedule' { Initialize-Scheduled }
}

if ($env:NON_ZERO_EXIT) { exit 258 }
#endregion Main
