#!/usr/bin/env pwsh

param(
    [string]$Path = "www/news",
    [string]$Command,
    # Parameter for Invoke-Post, path to the .htmraw file to process or create
    [string]$PostHtmRawPathParameter, 
    [string]$PostFilePath, # Alias/legacy name for PostHtmRawPathParameter for Invoke-Post
    # Parameter for Invoke-Edit, path to the .htmraw file to edit
    [Parameter(Mandatory = $false, HelpMessage = "Path to the .htmraw file to edit.")]
    [Alias("EditFilePath")]
    [string]$EditHtmRawPathParameter,
    [Parameter(Mandatory = $false, HelpMessage = "Run the script in interactive TUI mode.")]
    [switch]$Interactive
)

# Set interactive mode global flag
$Global:IsInteractiveMode = if ($Interactive.IsPresent) { $true } else { $false }
Write-Verbose "Interactive mode set to: $Global:IsInteractiveMode"

# --- Function to Initialize/Re-initialize Global Path Variables ---
function Set-GlobalPathVariables {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BaseContentPathFromParam # This is the value from -Path or user input
    )

    # Resolve ContentRoot: if $BaseContentPathFromParam is absolute, use it directly. Otherwise, join with script's parent directory.
    if ([System.IO.Path]::IsPathRooted($BaseContentPathFromParam)) {
        $Global:ContentRoot = $BaseContentPathFromParam
    } else {
        $Global:ContentRoot = Join-Path -Path $PSScriptRoot -ChildPath $BaseContentPathFromParam
    }
    # Attempt to resolve to a full, canonical path.
    $Global:ContentRoot = (Resolve-Path -Path $Global:ContentRoot -ErrorAction SilentlyContinue).Path
    if (-not $Global:ContentRoot) {
        Write-Warning "The specified content path '$BaseContentPathFromParam' could not be resolved. Some operations may fail."
        # Fallback to a non-resolved path or handle error more gracefully if needed
        if ([System.IO.Path]::IsPathRooted($BaseContentPathFromParam)) { $Global:ContentRoot = $BaseContentPathFromParam } 
        else { $Global:ContentRoot = Join-Path -Path $PSScriptRoot -ChildPath $BaseContentPathFromParam }
    }

    # Define other paths based on the (potentially overridden) ContentRoot
    $Global:TemplatesDir = Join-Path -Path $Global:ContentRoot -ChildPath "cms_config"
    $Global:HeaderTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_header.txt"
    $Global:FooterTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_footer.txt"
    $Global:BeginTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_begin.txt"
    $Global:EndTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_end.txt"
    $Global:SkeletonTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_skeleton.txt"
    $Global:IndexFile = Join-Path -Path $Global:ContentRoot -ChildPath "index.html"
    $Global:AllPostsFile = Join-Path -Path $Global:ContentRoot -ChildPath "all_posts.html"
    $Global:AllTagsFile = Join-Path -Path $Global:ContentRoot -ChildPath "all_tags.html"

    Write-Verbose "Global paths re-initialized. ContentRoot: $($Global:ContentRoot)"
    Write-Verbose "TemplatesDir: $($Global:TemplatesDir), IndexFile: $($Global:IndexFile)"
}

# --- Initial Setup of Global Variables ---
# Set your preferred editor here, e.g., "code.exe", "C:\Program Files\Notepad++\notepad++.exe", "subl.exe"
# If $null, the script will search for common editors.
$Global:PreferredEditor = $null 
$Global:NumberOfIndexArticles = 10 # Default, can be overridden by config file later
$Global:SiteTitle = "My PowerShell Blog" # Default, can be overridden
$Global:SiteAuthor = "PowerShell User" # Default, can be overridden

# Initialize global paths based on the -Path parameter (or its default)
Set-GlobalPathVariables -BaseContentPathFromParam $Path 


# --- Interactive Mode Logic (TUI for initial command/path) ---
if ($Global:IsInteractiveMode) {
    Write-Verbose "Interactive mode detected."

    # 1. Prompt for Content Path if not provided via -Path
    if (-not $PSBoundParameters.ContainsKey('Path')) {
        Write-Host "Current Content Root: $ContentRoot"
        $inputPath = Read-Host -Prompt "Enter new path for content root, or press Enter to keep current"
        if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
            if (Test-Path -Path $inputPath -IsValid) { # Basic validation, more robust check in Set-GlobalPathVariables
                Write-Verbose "User entered new path: $inputPath. Re-initializing global paths."
                $Path = $inputPath # Update $Path from param block to reflect user's choice for consistency
                Set-GlobalPathVariables -BaseContentPathFromParam $Path # Re-initialize all paths
            } else {
                Write-Warning "The path '$inputPath' seems invalid or inaccessible. Keeping current ContentRoot: $ContentRoot"
            }
        }
    }

    # 2. Prompt for Command if not provided via -Command
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $availableCommands = @(
            [pscustomobject]@{ Name = "post";    Description = "Create a new post or process an existing .htmraw file." }
            [pscustomobject]@{ Name = "edit";    Description = "Open an existing .htmraw file in an editor." }
            [pscustomobject]@{ Name = "rebuild"; Description = "Rebuild all HTML files from .htmraw sources and update all indexes." }
            # Placeholders for future commands:
            # [pscustomobject]@{ Name = "list";    Description = "List all published posts." } 
            # [pscustomobject]@{ Name = "tags";    Description = "List all tags." }
            [pscustomobject]@{ Name = "exit";    Description = "Exit Spelunker." }
        )
        
        Write-Host "`nPlease select a command to execute:" -ForegroundColor Yellow
        # Attempt Out-GridView first, fallback to Read-Host if it fails (e.g. non-interactive console)
        try {
            $selectedCommandEntry = $availableCommands | Out-GridView -Title "Select Spelunker Command" -PassThru -ErrorAction Stop
            if ($selectedCommandEntry) {
                $Command = $selectedCommandEntry.Name
                Write-Verbose "User selected command via Out-GridView: $Command"
            } else {
                Write-Warning "No command selected via Out-GridView."
                # Allow fallback to Read-Host or exit
            }
        } catch {
            Write-Verbose "Out-GridView failed or not available, falling back to Read-Host selection. Error: $($_.Exception.Message)"
            for ($i = 0; $i -lt $availableCommands.Count; $i++) {
                Write-Host ("{0,2}. {1,-10} - {2}" -f ($i + 1), $availableCommands[$i].Name, $availableCommands[$i].Description)
            }
            $choice = Read-Host -Prompt "Enter command number"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $availableCommands.Count) {
                $Command = $availableCommands[[int]$choice - 1].Name
                Write-Verbose "User selected command via Read-Host: $Command"
            } else {
                Write-Warning "Invalid selection '$choice'."
                # $Command remains empty or previously set
            }
        }

        if ([string]::IsNullOrWhiteSpace($Command) -or $Command -eq "exit") {
            Write-Host "No command selected or 'exit' chosen. Exiting Spelunker."
            exit
        }
    }
}

# --- Main Command Switch ---
Write-Verbose "Executing command: $Command"
# Placeholder functions
function Invoke-Rebuild {
    Write-Host "Starting Invoke-Rebuild. ContentRoot: $ContentRoot (Full: $((Resolve-Path $ContentRoot).Path))"
    
    Write-Host "Starting Invoke-Rebuild. ContentRoot: $ContentRoot (Full: $((Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path))" # Added SilentlyContinue
    Write-Verbose "Using ContentRoot: $ContentRoot, TemplatesDir: $TemplatesDir"
    
    # Ensure ContentRoot actually exists before trying to Get-ChildItem
    if (-not (Test-Path -Path $ContentRoot -PathType Container)) {
        Write-Error "ContentRoot directory not found: '$ContentRoot'. Please ensure the -Path parameter is correct and the directory exists."
        return
    }
    Write-Verbose "ContentRoot directory confirmed: $ContentRoot"

    $sourceFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    $processedCount = 0
    $errorCount = 0
    $generatedHtmlFiles = 0 # Specific counter for successfully generated HTML

    if ($null -eq $sourceFiles -or $sourceFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot to rebuild."
        # Still proceed to update indexes, as they might need to be generated (e.g., as empty)
    } else {
        Write-Host "Found $($sourceFiles.Count) .htmraw files to process."
    }

    # Get full path of ContentRoot once to ensure accurate relative path calculation
    $fullContentRootPath = (Resolve-Path $ContentRoot).Path

    foreach ($sourceFile in $sourceFiles) {
        try {
            Write-Verbose "Processing source file: $($sourceFile.FullName)"
            $fullSourcePath = $sourceFile.FullName
            
            $relativePath = $fullSourcePath.Substring($fullContentRootPath.Length)
            if ($relativePath.Length -gt 0 -and -not ($relativePath.StartsWith('/') -or $relativePath.StartsWith('\'))) {
                $relativePath = [System.IO.Path]::DirectorySeparatorChar + $relativePath
            }
            $relativeDir = Split-Path -Path $relativePath
            $outputFileName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name) + ".html"
            $finalOutputDir = Join-Path -Path $ContentRoot -ChildPath $relativeDir
            $outputFilePath = Join-Path -Path $finalOutputDir -ChildPath $outputFileName
            Write-Verbose "Output target for $($sourceFile.Name) is $outputFilePath"

            if (-not (Test-Path $finalOutputDir -PathType Container)) {
                Write-Verbose "Output directory $finalOutputDir does not exist, creating..."
                New-Item -ItemType Directory -Path $finalOutputDir -Force -ErrorAction Stop | Out-Null
                Write-Host "Created directory: $finalOutputDir"
            }

            $timestamp = (Get-Item $sourceFile.FullName).LastWriteTime
            
            # New-BlogPostHtml handles its own success/error messages
            New-BlogPostHtml -SourceFilePath $sourceFile.FullName -OutputFilePath $outputFilePath -Timestamp $timestamp
            
            # Basic check if HTML was generated
            if (Test-Path $outputFilePath -PathType Leaf) {
                $generatedHtmlFiles++
            }
            $processedCount++
        } catch {
            # Catching exceptions from New-Item or other critical errors in the loop itself
            Write-Error "Critical error encountered while processing file $($sourceFile.FullName): $($_.Exception.Message)"
            $errorCount++
        }
    }

    Write-Host "--- Rebuild Summary ---"
    Write-Host "Total .htmraw files found: $($sourceFiles.Count)"
    Write-Host "Files processed for HTML generation: $processedCount"
    Write-Host "HTML files successfully generated: $generatedHtmlFiles"
    Write-Host "Errors during HTML generation: $errorCount"
    
    Write-Verbose "Starting index updates after processing posts..."
    Update-MainIndex 
    Update-AllPostsIndex 
    Update-TagsIndex 
    Write-Host "--- Indexing Complete ---"
    Write-Host "Rebuild process finished."
}

# Function to open a specified file in an editor
function Invoke-Edit {
    param(
        # Parameter is no longer mandatory here; logic below will handle interactive selection if not provided.
        [string]$EditFilePathParameter 
    )
    
    $ResolvedEditPath = $null

    if (-not ([string]::IsNullOrWhiteSpace($EditFilePathParameter))) {
        Write-Verbose "Invoke-Edit started with provided parameter: $EditFilePathParameter"
        $ResolvedEditPath = $EditFilePathParameter
        if (-not ([System.IO.Path]::IsPathRooted($ResolvedEditPath))) {
            Write-Verbose "Provided path '$ResolvedEditPath' is relative. Resolving against ContentRoot: $Global:ContentRoot"
            $ResolvedEditPath = Join-Path -Path $Global:ContentRoot -ChildPath $ResolvedEditPath
        }
        try {
            $ResolvedEditPath = (Resolve-Path -LiteralPath $ResolvedEditPath -ErrorAction Stop).Path 
            Write-Verbose "Path resolved to: $ResolvedEditPath"
            if (-not (Test-Path -LiteralPath $ResolvedEditPath -PathType Leaf)) {
                Write-Error "File not found or is not a file at the provided path: $ResolvedEditPath"
                return
            }
        } catch {
            Write-Error "Error resolving or accessing provided file path '$EditFilePathParameter': $($_.Exception.Message)"
            return
        }
    } elseif ($Global:IsInteractiveMode) {
        Write-Verbose "Invoke-Edit started in interactive mode without a pre-defined file path."
        Write-Host "Please select an .htmraw file to edit:" -ForegroundColor Yellow
        
        $availableFiles = Get-ChildItem -Path $Global:ContentRoot -Filter *.htmraw -Recurse -File -ErrorAction SilentlyContinue | 
            Select-Object FullName, @{Name="RelativePath"; Expression={$_.FullName.Substring($Global:ContentRoot.Length).TrimStart('\/')}}, Name, LastWriteTime, DirectoryName |
            Sort-Object RelativePath

        if ($null -eq $availableFiles -or $availableFiles.Count -eq 0) {
            Write-Warning "No .htmraw files found in '$($Global:ContentRoot)' or its subdirectories."
            return
        }
        
        $selectedFile = $null
        try {
            $selectedFile = $availableFiles | Out-GridView -Title "Select .htmraw File to Edit" -PassThru -ErrorAction Stop
        } catch {
            Write-Warning "Out-GridView is not available or failed. Error: $($_.Exception.Message)"
            # Fallback to a simpler list if Out-GridView fails (though less ideal for many files)
            Write-Host "Available files to edit:"
            for($i=0; $i -lt $availableFiles.Count; $i++) {
                Write-Host ("{0,3}: {1}" -f ($i+1), $availableFiles[$i].RelativePath)
            }
            $choice = Read-Host -Prompt "Enter number of file to edit"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $availableFiles.Count) {
                $selectedFile = $availableFiles[[int]$choice - 1]
            }
        }

        if ($null -eq $selectedFile) {
            Write-Warning "No file selected for editing."
            return
        }
        $ResolvedEditPath = $selectedFile.FullName # Use FullName as it's already an absolute path
        Write-Verbose "User selected file: $ResolvedEditPath"
    } else {
        Write-Error "The 'edit' command requires a file path to be specified via -EditHtmRawPathParameter (or -EditFilePath) when not in interactive mode."
        return
    }
    
    Write-Host "Attempting to edit file: $ResolvedEditPath"

    # Editor Launch (common logic for both parameter-provided and interactively selected path)
    $editorCommand = Get-EditorCommand
    if (-not [string]::IsNullOrEmpty($editorCommand)) {
        Write-Verbose "Attempting to open '$ResolvedEditPath' with editor: $editorCommand"
        try {
            Start-Process -FilePath $editorCommand -ArgumentList $ResolvedEditPath -ErrorAction Stop
            $editorExeName = ($editorCommand -split '[\\/]')[-1] 
            Write-Host "Launched editor '$editorExeName' for '$ResolvedEditPath'."
        }
        catch {
            Write-Warning "Failed to launch editor '$editorCommand' for '$ResolvedEditPath'. Error: $($_.Exception.Message)"
        }
    }
    else {
        # Get-EditorCommand already issues a Write-Warning if no editor is found.
        Write-Host "No suitable editor found or configured to open '$ResolvedEditPath'. Please open it manually."
    }
}

# Function to determine the editor command to use
function Get-EditorCommand {
    Write-Verbose "Attempting to determine editor command..."

    # 1. Check Preferred Editor
    if (-not ([string]::IsNullOrWhiteSpace($Global:PreferredEditor))) {
        Write-Verbose "Checking for preferred editor: '$Global:PreferredEditor'"
        $foundCommand = Get-Command -Name $Global:PreferredEditor -ErrorAction SilentlyContinue
        if ($null -ne $foundCommand) {
            Write-Verbose "Using preferred editor: $($foundCommand.Source)"
            return $foundCommand.Source
        } else {
            Write-Verbose "Preferred editor '$Global:PreferredEditor' not found in PATH."
        }
    } else {
        Write-Verbose "No preferred editor set in `$Global:PreferredEditor."
    }

    # 2. Check Common Editors
    Write-Verbose "Checking common editors."
    $commonEditors = @("code.exe", "code-insiders.exe", "notepad++.exe", "subl.exe", "atom.exe", "geany.exe", "notepad.exe") 
    # Added code-insiders based on common usage.
    
    foreach ($editorName in $commonEditors) {
        Write-Verbose "Checking for editor: $editorName"
        $foundCommand = Get-Command -Name $editorName -ErrorAction SilentlyContinue
        if ($null -ne $foundCommand) {
            Write-Verbose "Found common editor: $($foundCommand.Source)"
            return $foundCommand.Source
        }
    }

    # 3. Fallback/Not Found
    Write-Warning "No suitable editor found after checking preferred and common list. Please set `$Global:PreferredEditor or install a common editor."
    return $null
}

# Function to update the main index.html page
function Update-MainIndex {
    Write-Host "Updating main index page: $IndexFile"
    Write-Verbose "Global IndexFile path: $IndexFile, NumberOfIndexArticles: $NumberOfIndexArticles"

    # 1. Find relevant .htmraw source files
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build main index."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. Main index will be empty or reflect no posts."
        # Allow to proceed to generate an empty index if that's the case
    }
    
    $postObjects = @()
    # Resolve path once for all substring operations
    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path
    if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting main index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing $($htmrawFile.FullName) for main index."
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) { # Added ErrorAction
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) { # Parse-HtmRawContent itself logs, this is a fallback.
            Write-Warning "Could not parse $($htmrawFile.FullName) or it returned no data, skipping for index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'


        $timestamp = $htmrawFile.LastWriteTime
        $htmlFilePath = Join-Path -Path (Split-Path -Path $htmrawFile.FullName) -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($htmrawFile.Name) + ".html")
        Write-Verbose "Source: $($htmrawFile.Name), HTML Link: $htmlLink, Timestamp: $timestamp, Expected HTML Path: $htmlFilePath"
        
        $summary = "Summary not available."
        if (Test-Path $htmlFilePath -PathType Leaf) {
            Write-Verbose "Extracting summary from $htmlFilePath"
            $htmlFileContent = Get-HtmRawSourceFile -FilePath $htmlFilePath 
            if ($htmlFileContent) { # Check if content was actually read
                $bodyMatch = $htmlFileContent | Select-String -Pattern '(?s)<body>(.*?)</body>' 
                $postBodyHtml = if ($bodyMatch) { $bodyMatch.Matches[0].Groups[1].Value } else { $htmlFileContent } 

                if ($postBodyHtml) {
                    $splitByHr = $postBodyHtml -split '<\s*hr\s*/?\s*>', 2 
                    $contentBeforeHr = $splitByHr[0]
                    $summaryText = ConvertFrom-HtmlToText -HtmlContent $contentBeforeHr
                    $summary = if ($summaryText.Length -gt 300) { 
                        $summaryText.Substring(0, 300).Trim() + "..."
                    } else { 
                        $summaryText.Trim() 
                    }
                    Write-Verbose "Summary for $($htmrawFile.Name): '$($summary.Substring(0, [System.Math]::Min($summary.Length, 50)))...'" # Log a snippet
                }
            } else {
                Write-Warning "Could not read HTML file $htmlFilePath for summary extraction (it might be empty or unreadable)."
            }
        } else {
            Write-Warning "Generated HTML file $htmlFilePath not found for summary extraction. Post $($htmrawFile.Name) might not have been generated yet, or path is incorrect."
        }
        
        $postObjects += [PSCustomObject]@{
            Title           = $parsedData.Title
            HtmlRelativePath = $htmlLink
            Timestamp       = $timestamp
            Summary         = $summary
            SourceHtmRawPath = $htmrawFile.FullName
        }
    }
    Write-Verbose "Finished collecting post data for main index. $($postObjects.Count) posts considered."

    # 2. Sort Posts (newest first) and select top N
    Write-Verbose "Sorting posts and selecting top $NumberOfIndexArticles for main index."
    $sortedPosts = $postObjects | Sort-Object -Property Timestamp -Descending | Select-Object -First $NumberOfIndexArticles

    # 3. Generate HTML content for the index
    $indexContentBuilder = New-Object System.Text.StringBuilder
    if ($sortedPosts.Count -gt 0) {
        Write-Verbose "Generating list entries for main index page with $($sortedPosts.Count) posts."
        foreach ($post in $sortedPosts) {
            [void]$indexContentBuilder.AppendLine('<div class="post-entry">')
            [void]$indexContentBuilder.AppendLine("    <h3><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a></h3>")
            [void]$indexContentBuilder.AppendLine("    <p class=""summary"">$($post.Summary)</p>")
            [void]$indexContentBuilder.AppendLine("    <p class=""date"">$($post.Timestamp.ToString('yyyy-MM-dd HH:mm'))</p>") 
            [void]$indexContentBuilder.AppendLine('</div>')
            [void]$indexContentBuilder.AppendLine('<hr />')
        }
    } else {
        Write-Verbose "No posts to list on main index page."
        [void]$indexContentBuilder.AppendLine("<p>No posts yet. Stay tuned!</p>")
    }

    # 4. Construct Full Index Page
    Write-Verbose "Constructing full HTML for $IndexFile."
    $headerContent = Get-TemplateContent -TemplatePath $HeaderTemplate
    $footerContent = Get-TemplateContent -TemplatePath $FooterTemplate
    $beginContent = Get-TemplateContent -TemplatePath $BeginTemplate
    $endContent = Get-TemplateContent -TemplatePath $EndTemplate

    if ($null -eq $headerContent -or $null -eq $footerContent -or $null -eq $beginContent -or $null -eq $endContent) {
        Write-Error "One or more base template files ($HeaderTemplate, $FooterTemplate, $BeginTemplate, $EndTemplate) could not be read or are empty for index generation. Aborting $IndexFile generation."
        return
    }
    
    $headerWithTitle = $headerContent -replace '</head>', "<title>$($SiteTitle) - Home</title></head>"

    $fullIndexHtml = New-Object System.Text.StringBuilder
    [void]$fullIndexHtml.Append($headerWithTitle)
    [void]$fullIndexHtml.Append($beginContent)
    [void]$fullIndexHtml.Append($indexContentBuilder.ToString())
    [void]$fullIndexHtml.Append($endContent)
    [void]$fullIndexHtml.Append($footerContent)

    try {
        Set-Content -Path $IndexFile -Value $fullIndexHtml.ToString() -Force -ErrorAction Stop
        Write-Host "Main index page updated: $IndexFile"
    } catch {
        Write-Error "Failed to write main index page to $IndexFile: $($_.Exception.Message)"
    }
}

function Invoke-Post {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PostHtmRawPathParameter 
    )
    Write-Verbose "Invoke-Post started for parameter: $PostHtmRawPathParameter"

    # 1. Path Resolution
    $ResolvedPostHtmRawPath = $PostHtmRawPathParameter
    if (-not ([System.IO.Path]::IsPathRooted($ResolvedPostHtmRawPath))) {
        Write-Verbose "Provided path '$ResolvedPostHtmRawPath' is relative. Resolving against ContentRoot: $ContentRoot"
        $ResolvedPostHtmRawPath = Join-Path -Path $ContentRoot -ChildPath $ResolvedPostHtmRawPath
    }
    
    # Attempt to get full path, which also helps normalize it
    try {
        # Resolve-Path can error if the path doesn't exist, even parts of it.
        # For new files, we need to construct the full path carefully.
        if (Test-Path $ResolvedPostHtmRawPath) {
            $ResolvedPostHtmRawPath = (Resolve-Path $ResolvedPostHtmRawPath -ErrorAction Stop).Path
            Write-Verbose "Path exists and resolved to: $ResolvedPostHtmRawPath"
        } else {
            # Path doesn't exist, construct full path for potential creation
            # GetFullPath can resolve '..' etc. Needs a base if $ResolvedPostHtmRawPath might still be relative
            $baseForGetFullPath = $PSScriptRoot 
            if ([System.IO.Path]::IsPathRooted($ContentRoot)) { $baseForGetFullPath = $ContentRoot }
            elseif(Test-Path (Join-Path $PSScriptRoot $ContentRoot)) { $baseForGetFullPath = (Resolve-Path (Join-Path $PSScriptRoot $ContentRoot)).Path}


            if (-not ([System.IO.Path]::IsPathRooted($ResolvedPostHtmRawPath))) {
                 # If still not rooted, join with our best guess for a base path.
                 $ResolvedPostHtmRawPath = Join-Path -Path $baseForGetFullPath -ChildPath $ResolvedPostHtmRawPath
            }
            $ResolvedPostHtmRawPath = [System.IO.Path]::GetFullPath($ResolvedPostHtmRawPath)
            Write-Verbose "Path does not exist yet, constructed full path: $ResolvedPostHtmRawPath"
        }
    } catch {
        Write-Error "Error resolving path '$PostHtmRawPathParameter': $($_.Exception.Message)"
        return
    }
    
    Write-Host "Effective post source file target: $ResolvedPostHtmRawPath"

    # 2. File Existence Check and Skeleton Copy
    $newFileCreated = $false # Flag to track if we created the file in this run
    if (-not (Test-Path $ResolvedPostHtmRawPath -PathType Leaf)) {
        Write-Host "Source file '$ResolvedPostHtmRawPath' does not exist. Attempting to create new post from skeleton..."
        $TargetDirectory = Split-Path -Path $ResolvedPostHtmRawPath
        if (-not (Test-Path $TargetDirectory -PathType Container)) {
            Write-Verbose "Target directory '$TargetDirectory' does not exist. Attempting to create."
            try {
                New-Item -ItemType Directory -Path $TargetDirectory -Force -ErrorAction Stop | Out-Null
                Write-Host "Created directory: $TargetDirectory"
            } catch {
                Write-Error "Failed to create directory '$TargetDirectory': $($_.Exception.Message)"
                return
            }
        }
        try {
            $SkeletonContent = Get-TemplateContent -TemplatePath $SkeletonTemplate
            if ($null -eq $SkeletonContent) { # Check if skeleton content itself is null
                Write-Error "Skeleton template ($SkeletonTemplate) content is empty or could not be read. Cannot create new post from skeleton."
                return
            }
            Set-Content -Path $ResolvedPostHtmRawPath -Value $SkeletonContent -Force -ErrorAction Stop
            Write-Host "New post created from skeleton: $ResolvedPostHtmRawPath"
            $newFileCreated = $true

            # Interactive Tag Input for new posts
            if ($Global:IsInteractiveMode) { # This if block is for tags
                Write-Verbose "Interactive mode: Prompting for tags for new post $ResolvedPostHtmRawPath"
                
                # Gather existing tags to suggest
                $allTagsFromAllPosts = [System.Collections.Generic.List[string]]::new()
                $tempAllHtmRawFiles = Get-ChildItem -Path $Global:ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
                foreach ($tempFileInScan in $tempAllHtmRawFiles) {
                    if ($tempFileInScan.FullName -ne $ResolvedPostHtmRawPath -and -not $tempFileInScan.FullName.StartsWith((Resolve-Path $Global:TemplatesDir -ErrorAction SilentlyContinue).Path)) {
                        $tempParsed = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $tempFileInScan.FullName)
                        if ($null -ne $tempParsed -and $null -ne $tempParsed.Tags) {
                            $tempParsed.Tags | ForEach-Object { $allTagsFromAllPosts.Add($_) }
                        }
                    }
                }
                $existingUniqueTags = $allTagsFromAllPosts | Sort-Object -Unique
                
                $selectedExistingTags = @()
                if ($existingUniqueTags.Count -gt 0) {
                    Write-Host "`nSelect existing tags (optional). Press OK for selections, Cancel to skip." -ForegroundColor Yellow
                    # Out-GridView can be finicky in some terminals / ISE, but is best effort.
                    try {
                        $selectedExistingTags = $existingUniqueTags | Out-GridView -Title "Select Existing Tags for '$($ResolvedPostHtmRawPath | Split-Path -Leaf)'" -PassThru -ErrorAction Stop
                        if ($null -eq $selectedExistingTags) { $selectedExistingTags = @() } 
                        Write-Verbose "User selected existing tags via Out-GridView: $($selectedExistingTags -join ', ')"
                    } catch {
                         Write-Warning "Out-GridView for existing tag selection failed or was skipped. You can enter all tags manually. Error: $($_.Exception.Message)"
                         # Display manually if Out-GridView fails
                         Write-Host "Available existing tags:"
                         $existingUniqueTags | ForEach-Object { Write-Host "- $_" }
                         $tagsToSelectFromList = Read-Host -Prompt "Enter existing tags to use from the list above, separated by commas (or press Enter to skip)"
                         if (-not [string]::IsNullOrWhiteSpace($tagsToSelectFromList)) {
                             $selectedExistingTags = $tagsToSelectFromList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $existingUniqueTags -contains $_ }
                         }
                    }
                } else {
                    Write-Verbose "No existing tags found to suggest."
                }

                $newTagsString = Read-Host -Prompt "Enter any NEW tags, separated by commas (optional)"
                $newTags = @()
                if (-not [string]::IsNullOrWhiteSpace($newTagsString)) {
                    $newTags = $newTagsString.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                }
                Write-Verbose "User entered new tags: $($newTags -join ', ')"

                $finalTags = ($selectedExistingTags + $newTags) | Sort-Object -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                if ($finalTags.Count -gt 0) {
                    Write-Verbose "Final combined tags: $($finalTags -join ', ')"
                    try {
                        $fileContent = Get-Content -Raw -Path $ResolvedPostHtmRawPath -ErrorAction Stop
                        # Regex to find <!--RawTags: followed by anything except -->, then -->
                        # This handles cases where tags might be empty or have various characters.
                        $updatedContent = $fileContent -replace '<!--RawTags:.*?-->', "<!--RawTags:$($finalTags -join ',')-->"
                        Set-Content -Path $ResolvedPostHtmRawPath -Value $updatedContent -Force -ErrorAction Stop
                        Write-Host "Updated tags in '$ResolvedPostHtmRawPath' to: $($finalTags -join ', ')" -ForegroundColor Green
                    } catch {
                        Write-Error "Failed to update tags in '$ResolvedPostHtmRawPath': $($_.Exception.Message)"
                    }
                } else {
                    # If skeleton had default tags and user removed them all, this path might be taken.
                    # Or if user provided no tags and selected none.
                    # We might want to ensure the RawTags line is still present but empty, e.g. <!--RawTags:-->
                    Write-Verbose "No final tags specified. Default tags from skeleton (if any) will be used or tags will be empty."
                    # Optionally, ensure the line is at least <!--RawTags:-->
                    try {
                        $fileContent = Get-Content -Raw -Path $ResolvedPostHtmRawPath -ErrorAction Stop
                        if ($fileContent -notmatch '<!--RawTags:.*?-->') {
                             # If the line is somehow missing, add it. This is defensive.
                             # For simplicity now, assuming skeleton always provides it.
                        } else {
                             # If user wants no tags, ensure the line is empty of tags
                             $updatedContent = $fileContent -replace '<!--RawTags:.*?-->', "<!--RawTags:-->"
                             if ($updatedContent -ne $fileContent) {
                                Set-Content -Path $ResolvedPostHtmRawPath -Value $updatedContent -Force -ErrorAction Stop
                                Write-Host "Cleared default tags in '$ResolvedPostHtmRawPath' as per user input." -ForegroundColor Green
                             }
                        }
                    } catch {
                         Write-Error "Failed to clear/verify tags in '$ResolvedPostHtmRawPath': $($_.Exception.Message)"
                    }
                }
            } # End if ($Global:IsInteractiveMode)

            # Launch editor for the new post
            $editorCommand = Get-EditorCommand
            if (-not [string]::IsNullOrEmpty($editorCommand)) {
                Write-Verbose "Attempting to open '$ResolvedPostHtmRawPath' with editor: $editorCommand"
                try {
                    # For GUI editors, often they detach, so no need for -PassThru or complex handling
                    Start-Process -FilePath $editorCommand -ArgumentList $ResolvedPostHtmRawPath -ErrorAction Stop
                    # Get just the executable name for the message
                    $editorExeName = ($editorCommand -split '[\\/]')[-1] 
                    Write-Host "Launched editor '$editorExeName' for '$ResolvedPostHtmRawPath'."
                }
                catch {
                    Write-Warning "Failed to launch editor '$editorCommand' for '$ResolvedPostHtmRawPath'. Error: $($_.Exception.Message)"
                }
            }
            else {
                # Get-EditorCommand already issues a Write-Warning if no editor is found.
                # This message gives context-specific advice for the Invoke-Post command.
                Write-Host "No suitable editor found or configured to open '$ResolvedPostHtmRawPath'. Please open it manually to edit."
            }
            
            # --- TUI Prompt for P/E/S for newly created files in interactive mode ---
            if ($Global:IsInteractiveMode -and $newFileCreated) {
                $userAction = ""
                do {
                    Write-Host "`nPost '$($ResolvedPostHtmRawPath | Split-Path -Leaf)' has been prepared/updated." -ForegroundColor Yellow
                    $choices = @(
                        [pscustomobject]@{ Name = "Publish"; Letter = "P"; Description = "Generate HTML and update indexes now." }
                        [pscustomobject]@{ Name = "Edit";    Letter = "E"; Description = "Re-open in editor / continue editing." }
                        [pscustomobject]@{ Name = "Save as Draft";   Letter = "S"; Description = "Skip HTML generation and index updates for now." }
                    )
                    $choices | ForEach-Object { Write-Host ("  [{0}] {1,-15} - {2}" -f $_.Letter, $_.Name, $_.Description) }
                    $actionChoice = Read-Host -Prompt "Enter action (P/E/S)"
                    
                    $userAction = $actionChoice.ToUpper()

                    switch ($userAction) {
                        "P" { Write-Verbose "User chose to Publish." }
                        "E" {
                            Write-Verbose "User chose to Edit again."
                            $editorToReopen = Get-EditorCommand
                            if (-not [string]::IsNullOrEmpty($editorToReopen)) {
                                Write-Verbose "Attempting to re-open '$ResolvedPostHtmRawPath' with editor: $editorToReopen"
                                try {
                                    Start-Process -FilePath $editorToReopen -ArgumentList $ResolvedPostHtmRawPath -ErrorAction Stop
                                } catch { Write-Warning "Failed to re-launch editor '$editorToReopen'. Error: $($_.Exception.Message)" }
                            } else { Write-Warning "No editor found to re-open." }
                        }
                        "S" {
                            Write-Verbose "User chose to Save as Draft."
                            Write-Host "Post '$ResolvedPostHtmRawPath' saved as a draft. HTML generation and index updates will be skipped." -ForegroundColor Green
                            return # Exit Invoke-Post entirely
                        }
                        default {
                            Write-Warning "Invalid selection. Please choose P, E, or S."
                            $userAction = "E" # Force loop to re-prompt by making it seem like Edit was chosen
                        }
                    }
                } while ($userAction -eq "E") # Loop as long as user wants to edit or enters invalid choice that defaults to E
            } # --- End TUI P/E/S Prompt ---

        } catch { # This catch is for the block that creates the new file from skeleton
            Write-Error "Failed to create new post from skeleton at $ResolvedPostHtmRawPath: $($_.Exception.Message)"
            return # Critical failure for this operation
        }
    } else { # This else is for if (-not (Test-Path $ResolvedPostHtmRawPath -PathType Leaf))
        Write-Host "Processing existing post: $ResolvedPostHtmRawPath"
        # For existing posts, we don't show the P/E/S prompt, just proceed to generate.
        # If we wanted P/E/S for existing posts, $newFileCreated would need different logic.
    }

    # 3. Determine Output Path (This is fine, but $ResolvedPostHtmRawPath should be used with -LiteralPath)
    $OutputFileName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedPostHtmRawPath) + ".html"
    $OutputFilePath = Join-Path -Path (Split-Path -Path $ResolvedPostHtmRawPath) -ChildPath $OutputFileName
    Write-Verbose "Output HTML file will be: $OutputFilePath"

    # 4. Process the Post
    $Timestamp = (Get-Item -LiteralPath $ResolvedPostHtmRawPath).LastWriteTime 
    Write-Verbose "Timestamp for post $ResolvedPostHtmRawPath is $Timestamp"

    New-BlogPostHtml -SourceFilePath $ResolvedPostHtmRawPath -OutputFilePath $OutputFilePath -Timestamp $Timestamp
    
    if (-not (Test-Path $OutputFilePath -PathType Leaf)) {
        Write-Warning "HTML file $OutputFilePath was not generated as expected by New-BlogPostHtml. Skipping index updates for this post."
        return
    }

    Write-Verbose "Post HTML generation appears successful. Proceeding to update indexes."
    Update-MainIndex 
    Update-AllPostsIndex 
    Update-TagsIndex 
    Write-Host "Invoke-Post for '$($PostHtmRawPathParameter)' completed."
}

# Function to update tag index pages (all_tags.html and individual tag_*.html files)
function Update-TagsIndex {
    Write-Host "Updating tag index pages..."
    Write-Verbose "Global AllTagsFile path: $AllTagsFile"

    # 1. Initialize Data Structures
    $tagsCollection = @{}

    # 2. Find Source Files & Gather Tag Data
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build tag collections."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. Tag indexes will be empty or reflect no posts."
        # Allow to proceed to generate empty/default tag pages
    }
    
    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path
     if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting Tags index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing tags for $($htmrawFile.FullName)"
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) {
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) {
            Write-Warning "Could not parse $($htmrawFile.FullName), skipping for Tags index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'
        
        $postTimestamp = $htmrawFile.LastWriteTime

        foreach ($rawTag in $parsedData.Tags) {
            $tag = $rawTag.Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) {
                continue
            }
            Write-Verbose "Found tag '$tag' in $($htmrawFile.Name)"

            if (-not $tagsCollection.ContainsKey($tag)) {
                $tagsCollection[$tag] = [System.Collections.Generic.List[PSCustomObject]]::new()
            }
            $tagsCollection[$tag].Add([PSCustomObject]@{
                Title            = $parsedData.Title
                HtmlRelativePath = $htmlLink 
                Timestamp        = $postTimestamp
            })
        }
    }
    Write-Verbose "Finished collecting tags. Found $($tagsCollection.Keys.Count) unique tags."

    # 3. Sort Posts within Each Tag Collection
    Write-Verbose "Sorting posts within each tag collection..."
    foreach ($tagKey in $tagsCollection.Keys) {
        $tagsCollection[$tagKey] = $tagsCollection[$tagKey] | Sort-Object -Property Timestamp -Descending
    }

    # 4. Generate all_tags.html
    Write-Verbose "Generating $AllTagsFile..."
    $allTagsPageBuilder = New-Object System.Text.StringBuilder
    [void]$allTagsPageBuilder.AppendLine("<h1>All Tags</h1>")
    [void]$allTagsPageBuilder.AppendLine("<ul>")

    if ($tagsCollection.Keys.Count -gt 0) {
        foreach ($tagKey in ($tagsCollection.Keys | Sort-Object)) { # Sort tags alphabetically for the list
            $safeTagFileName = "tag_$($tagKey -replace '[^a-zA-Z0-9_]', '_').html"
            Write-Verbose "Adding tag '$tagKey' to $AllTagsFile, linking to $safeTagFileName"
            [void]$allTagsPageBuilder.AppendLine("<li><a href=""$safeTagFileName"">$tagKey</a> ($($tagsCollection[$tagKey].Count) posts)</li>")
        }
    } else {
        Write-Verbose "No tags found to list in $AllTagsFile."
        [void]$allTagsPageBuilder.AppendLine("<li>No tags found.</li>")
    }
    [void]$allTagsPageBuilder.AppendLine("</ul>")

    $headerContent = Get-TemplateContent -TemplatePath $HeaderTemplate
    $footerContent = Get-TemplateContent -TemplatePath $FooterTemplate
    $beginContent = Get-TemplateContent -TemplatePath $BeginTemplate
    $endContent = Get-TemplateContent -TemplatePath $EndTemplate

    if ($null -eq $headerContent -or $null -eq $footerContent -or $null -eq $beginContent -or $null -eq $endContent) {
        Write-Error "One or more base template files ($HeaderTemplate, $FooterTemplate, $BeginTemplate, $EndTemplate) could not be read for All Tags page. Aborting $AllTagsFile generation."
        # Continue to individual tag pages if base templates are fine, but AllTagsFile might be missing.
    } else {
        $headerWithSiteTitleAllTags = $headerContent -replace '</head>', "<title>$($SiteTitle) - All Tags</title></head>"
        $fullAllTagsHtml = "$headerWithSiteTitleAllTags$beginContent$($allTagsPageBuilder.ToString())$endContent$footerContent"
        try {
            Set-Content -Path $AllTagsFile -Value $fullAllTagsHtml -Force -ErrorAction Stop
            Write-Host "All Tags index page updated: $AllTagsFile"
        } catch {
            Write-Error "Failed to write All Tags index page to $AllTagsFile: $($_.Exception.Message)"
        }
    }

    # 5. Generate Individual tag_TAGNAME.html Pages
    Write-Verbose "Generating individual tag pages..."
    if ($null -eq $headerContent -or $null -eq $footerContent -or $null -eq $beginContent -or $null -eq $endContent) {
         Write-Warning "Skipping generation of individual tag pages due to missing base templates (problem noted above)."
    } else {
        foreach ($tagKey in $tagsCollection.Keys) {
            $safeTagFileName = "tag_$($tagKey -replace '[^a-zA-Z0-9_]', '_').html"
            $tagPagePath = Join-Path -Path $ContentRoot -ChildPath $safeTagFileName
            Write-Verbose "Generating tag page for '$tagKey' at $tagPagePath"

            $singleTagPageBuilder = New-Object System.Text.StringBuilder
            [void]$singleTagPageBuilder.AppendLine("<h1>Posts tagged ""$tagKey""</h1>")
            [void]$singleTagPageBuilder.AppendLine("<ul>")

            if ($tagsCollection[$tagKey].Count -gt 0) {
                 foreach ($post in $tagsCollection[$tagKey]) { # Already sorted
                    $formattedDate = $post.Timestamp.ToString("dddd, MMMM dd, yyyy")
                    [void]$singleTagPageBuilder.AppendLine("<li><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a> - $formattedDate</li>")
                }
            } else { # Should not happen if tag exists in collection, but defensive
                [void]$singleTagPageBuilder.AppendLine("<li>No posts found for this tag.</li>")
            }
            [void]$singleTagPageBuilder.AppendLine("</ul>")
            
            $headerWithTagTitle = $headerContent -replace '</head>', "<title>$($SiteTitle) - Posts tagged $tagKey</title></head>"
            $fullSingleTagHtml = "$headerWithTagTitle$beginContent$($singleTagPageBuilder.ToString())$endContent$footerContent"

            try {
                Set-Content -Path $tagPagePath -Value $fullSingleTagHtml -Force -ErrorAction Stop
                Write-Host "Tag page generated: $tagPagePath"
            } catch {
                Write-Error "Failed to write tag page to $tagPagePath: $($_.Exception.Message)"
            }
        }
    }
    Write-Host "Tag index pages update complete."
}

# Function to update the all_posts.html page
function Update-AllPostsIndex {
    Write-Host "Updating All Posts index page: $AllPostsFile"
    Write-Verbose "Global AllPostsFile path: $AllPostsFile"

    # 1. Find relevant .htmraw source files
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build All Posts index."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
     if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. All Posts index will be empty or reflect no posts."
        # Allow to proceed to generate an empty index
    }
    
    $postObjects = @()
    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path 
    if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting All Posts index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing $($htmrawFile.FullName) for All Posts index."
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) {
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue 
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) {
            Write-Warning "Could not parse $($htmrawFile.FullName), skipping for All Posts index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'
        
        $postObjects += [PSCustomObject]@{
            Title            = $parsedData.Title
            HtmlRelativePath = $htmlLink
            Timestamp        = $htmrawFile.LastWriteTime
        }
    }
    Write-Verbose "Finished collecting post data for All Posts index. $($postObjects.Count) posts found."

    # 2. Sort Posts (newest first)
    Write-Verbose "Sorting posts for All Posts index."
    $sortedPosts = $postObjects | Sort-Object -Property Timestamp -Descending

    # 3. Generate HTML content for the All Posts page
    $allPostsContentBuilder = New-Object System.Text.StringBuilder
    [void]$allPostsContentBuilder.AppendLine("<h1>All Posts</h1>")

    $currentGroupHeader = ""
    if ($sortedPosts.Count -gt 0) {
        Write-Verbose "Generating list entries for All Posts page with $($sortedPosts.Count) posts."
        foreach ($post in $sortedPosts) {
            $postGroupHeader = $post.Timestamp.ToString("MMMM yyyy")
            if ($postGroupHeader -ne $currentGroupHeader) {
                if ($currentGroupHeader -ne "") { 
                    [void]$allPostsContentBuilder.AppendLine("</ul>")
                }
                $currentGroupHeader = $postGroupHeader
                Write-Verbose "Creating new group for All Posts index: $currentGroupHeader"
                [void]$allPostsContentBuilder.AppendLine("<h2>$currentGroupHeader</h2><ul>")
            }
            $formattedDate = $post.Timestamp.ToString("dddd, MMMM dd, yyyy")
            [void]$allPostsContentBuilder.AppendLine("<li><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a> - $formattedDate</li>")
        }
        [void]$allPostsContentBuilder.AppendLine("</ul>") 
    } else {
        Write-Verbose "No posts to list on All Posts page."
        [void]$allPostsContentBuilder.AppendLine("<p>No posts found.</p>")
    }

    # 4. Construct Full All Posts Page
    Write-Verbose "Constructing full HTML for $AllPostsFile."
    $headerContent = Get-TemplateContent -TemplatePath $HeaderTemplate
    $footerContent = Get-TemplateContent -TemplatePath $FooterTemplate
    $beginContent = Get-TemplateContent -TemplatePath $BeginTemplate
    $endContent = Get-TemplateContent -TemplatePath $EndTemplate

    if ($null -eq $headerContent -or $null -eq $footerContent -or $null -eq $beginContent -or $null -eq $endContent) {
        Write-Error "One or more base template files ($HeaderTemplate, $FooterTemplate, $BeginTemplate, $EndTemplate) could not be read or are empty for All Posts index generation. Aborting $AllPostsFile generation."
        return
    }
    
    $headerWithTitle = $headerContent -replace '</head>', "<title>$($SiteTitle) - All Posts</title></head>"

    $fullAllPostsHtml = New-Object System.Text.StringBuilder
    [void]$fullAllPostsHtml.Append($headerWithTitle)
    [void]$fullAllPostsHtml.Append($beginContent)
    [void]$fullAllPostsHtml.Append($allPostsContentBuilder.ToString())
    [void]$fullAllPostsHtml.Append($endContent)
    [void]$fullAllPostsHtml.Append($footerContent)

    try {
        Set-Content -Path $AllPostsFile -Value $fullAllPostsHtml.ToString() -Force -ErrorAction Stop
        Write-Host "All Posts index page updated: $AllPostsFile"
    } catch {
        Write-Error "Failed to write All Posts index page to $AllPostsFile: $($_.Exception.Message)"
    }
}

# Helper function to strip HTML tags
function ConvertFrom-HtmlToText {
    param (
        [string]$HtmlContent
    )
    Write-Verbose "Stripping HTML from content of length $($HtmlContent.Length)"
    return $HtmlContent -replace "<[^>]+>", ""
}

# Function to create HTML for a new blog post
function New-BlogPostHtml {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory=$true)]
        [string]$OutputFilePath,

        [datetime]$Timestamp = (Get-Date)
    )
    Write-Verbose "Starting New-BlogPostHtml for source: $SourceFilePath, output: $OutputFilePath"

    $RawContent = Get-HtmRawSourceFile -FilePath $SourceFilePath
    if ($null -eq $RawContent) { # Check for $null specifically
        Write-Error "Failed to read source file '$SourceFilePath' or file is empty for New-BlogPostHtml. Aborting this post."
        return 
    }
    Write-Verbose "Successfully read source file $SourceFilePath."

    $ParsedContent = Parse-HtmRawContent -RawContent $RawContent
    # Parse-HtmRawContent returns a PSCustomObject with defaults, so no specific null check needed here.
    Write-Verbose "Successfully parsed content for $SourceFilePath. Title: '$($ParsedContent.Title)'"

    $HeaderContent = Get-TemplateContent -TemplatePath $HeaderTemplate
    $FooterContent = Get-TemplateContent -TemplatePath $FooterTemplate
    $BeginContent = Get-TemplateContent -TemplatePath $BeginTemplate
    $EndContent = Get-TemplateContent -TemplatePath $EndTemplate

    if ($null -eq $HeaderContent -or $null -eq $FooterContent -or $null -eq $BeginContent -or $null -eq $EndContent) {
        Write-Error "One or more critical template files ($HeaderTemplate, $FooterTemplate, $BeginTemplate, $EndTemplate) could not be read or are empty. Aborting generation of '$OutputFilePath'."
        return
    }
    Write-Verbose "All base templates successfully read for '$OutputFilePath'."

    # Inject title into header
    # A simple approach: replace </head> with <title>$Title</title></head>
    # This assumes </head> exists and is unique enough for this simple replacement.
    $HeaderWithTitle = $HeaderContent -replace '</head>', "<title>$($ParsedContent.Title)</title></head>"

    # Construct HTML
    $HtmlBuilder = New-Object System.Text.StringBuilder
    [void]$HtmlBuilder.Append($HeaderWithTitle)
    [void]$HtmlBuilder.Append($BeginContent)
    [void]$HtmlBuilder.Append($ParsedContent.Body)

    # Add tags if any
    if ($ParsedContent.Tags.Count -gt 0) {
        $TagsString = $ParsedContent.Tags -join ", "
        [void]$HtmlBuilder.Append("<p>Tags: $TagsString</p>")
    }

    [void]$HtmlBuilder.Append($EndContent)
    [void]$HtmlBuilder.Append($FooterContent)

    try {
        Set-Content -Path $OutputFilePath -Value $HtmlBuilder.ToString() -Force -ErrorAction Stop
        Write-Host "Successfully generated $OutputFilePath (Timestamp: $Timestamp)"
    } catch {
        Write-Error "Failed to write HTML to $OutputFilePath: $($_.Exception.Message)" # More specific error
    }
}

# Function to get raw content from a file
function Get-HtmRawSourceFile {
    param (
        [string]$FilePath
    )
    Write-Verbose "Attempting to read file: $FilePath"
    try {
        if (Test-Path $FilePath -PathType Leaf) { # Ensure it's a file
            Write-Verbose "File confirmed to exist: $FilePath"
            return Get-Content -Raw -Path $FilePath -ErrorAction Stop
        } else {
            Write-Error "Source file not found or is not a file: $FilePath"
            return $null
        }
    } catch {
        Write-Error "Exception while reading file $FilePath: $($_.Exception.Message)" # More specific error
        return $null
    }
}

# Function to parse raw HTML content
function Parse-HtmRawContent {
    param (
        [string]$RawContent
    )
    Write-Verbose "Parsing raw content. Length: $($RawContent.Length)"

    $TitleMatch = $RawContent | Select-String -Pattern '<h1>(.*?)</h1>'
    $Title = if ($TitleMatch) { $TitleMatch.Matches[0].Groups[1].Value } else { "Untitled Post" }

    $TagsMatch = $RawContent | Select-String -Pattern '<!--RawTags:(.*?)-->'
    $Tags = if ($TagsMatch) {
        $TagsMatch.Matches[0].Groups[1].Value.Split(',') | ForEach-Object {$_.Trim()}
    } else {
        @()
    }

    $BodyMatch = $RawContent | Select-String -Pattern '(?s)<body>(.*?)</body>'
    $Body = if ($BodyMatch) { $BodyMatch.Matches[0].Groups[1].Value } else { "" }

    return [PSCustomObject]@{
        Title = $Title
        Tags = $Tags
        Body = $Body
        RawContent = $RawContent
    }
}

# Function to get content from a template file
function Get-TemplateContent {
    param (
        [string]$TemplatePath
    )
    Write-Verbose "Attempting to read template file: $TemplatePath"
    try {
        if (Test-Path $TemplatePath -PathType Leaf) { # Ensure it's a file
            Write-Verbose "Template file confirmed to exist: $TemplatePath"
            return Get-Content -Raw -Path $TemplatePath -ErrorAction Stop
        } else {
            Write-Error "Template file not found or is not a file: $TemplatePath"
            return $null
        }
    } catch {
        Write-Error "Exception while reading template file $TemplatePath: $($_.Exception.Message)" # More specific error
        return $null
    }
}

# Command handling
switch ($Command) {
    "rebuild" {
        Invoke-Rebuild
    }
    "post" {
        # $PSBoundParameters contains parameters explicitly passed to the script.
        # We need to ensure 'PostHtmRawPathParameter' (or whatever name we give the param in Invoke-Post)
        # is correctly passed if the user specifies it with a similar name on the command line.
        # The script's main param() block does not define -PostFilePath, so it won't be in $PSBoundParameters directly
        # if called like ./spelunker.ps1 -Command post -PostFilePath foo.htmraw
        # Instead, PowerShell passes extra parameters if the command (Invoke-Post) accepts them.
        # Let's assume the user calls: ./spelunker.ps1 -Command post drafts/post.htmraw
        # $args would contain 'drafts/post.htmraw' if not explicitly named.
        # For robust handling, we should add PostHtmRawPathParameter to the main param() block
        # or rely on $args if Invoke-Post is called directly with it.

        # Given current script structure, Invoke-Post is called with a named parameter.
        # The main script needs a way to receive this path.
        # Let's assume the command line is like:
        # ./spelunker.ps1 -Command post -SpecificPostPath "drafts/my-post.htmraw"
        # And the main param() block is updated to: param([string]$Path = "www/news", [string]$Command, [string]$SpecificPostPath)
        # Then, in the switch: Invoke-Post -PostHtmRawPathParameter $SpecificPostPath

        # For now, let's adjust the switch to expect $PSBoundParameters['PostHtmRawPathParameter']
        # This means the user *must* call it like:
        # ./spelunker.ps1 -Command post -PostHtmRawPathParameter "drafts/my-post.htmraw"
        # And the main param block must be updated.

        if ($PSBoundParameters.ContainsKey('PostHtmRawPathParameter')) {
            Invoke-Post -PostHtmRawPathParameter $PSBoundParameters['PostHtmRawPathParameter']
        } elseif ($PSBoundParameters.ContainsKey('PostFilePath')) {
            # Legacy or alternative naming, let's support it for now.
            Invoke-Post -PostHtmRawPathParameter $PSBoundParameters['PostFilePath']
        }
        else {
            Write-Error "For -Command 'post', please specify -PostHtmRawPathParameter or -PostFilePath."
        }
    }
    "edit" {
        $filePathToEdit = $null
        if ($PSBoundParameters.ContainsKey('EditHtmRawPathParameter')) {
            $filePathToEdit = $EditHtmRawPathParameter
        } elseif ($PSBoundParameters.ContainsKey('EditFilePath')) { # Alias for EditHtmRawPathParameter
            $filePathToEdit = $EditFilePath 
        }
        # Invoke-Edit will handle interactive prompting if $filePathToEdit is $null and mode is interactive.
        # It will also handle erroring out if $filePathToEdit is $null and not interactive.
        Invoke-Edit -EditFilePathParameter $filePathToEdit
    }
    default {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            Write-Error "No command specified. Use -Command <command_name> (e.g., post, edit, rebuild) or run with the -Interactive switch for a menu."
        } else {
            Write-Error "Unknown command: '$Command'. Valid commands are post, edit, rebuild. Or use -Interactive for a menu."
        }
    }
}
