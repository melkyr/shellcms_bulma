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
    [string]$EditHtmRawPathParameter
)

# Global variables
# Set your preferred editor here, e.g., "code.exe", "C:\Program Files\Notepad++\notepad++.exe", "subl.exe"
# If $null, the script will search for common editors.
$Global:PreferredEditor = $null 
$NumberOfIndexArticles = 10
$SiteTitle = "My PowerShell Blog"
$SiteAuthor = "PowerShell User"

# Resolve ContentRoot: if -Path is absolute, use it directly. Otherwise, join with script's parent directory.
$EffectivePath = if ([System.IO.Path]::IsPathRooted($Path)) {
    $Path
} else {
    Join-Path -Path $PSScriptRoot -ChildPath $Path # $PSScriptRoot is the directory of the script
}
$ContentRoot = $EffectivePath 

# Define other paths based on the (potentially overridden) ContentRoot
$TemplatesDir = Join-Path -Path $ContentRoot -ChildPath "cms_config"
$HeaderTemplate = Join-Path -Path $TemplatesDir -ChildPath "cms_header.txt"
$FooterTemplate = Join-Path -Path $TemplatesDir -ChildPath "cms_footer.txt"
$BeginTemplate = Join-Path -Path $TemplatesDir -ChildPath "cms_begin.txt"
$EndTemplate = Join-Path -Path $TemplatesDir -ChildPath "cms_end.txt"
$SkeletonTemplate = Join-Path -Path $TemplatesDir -ChildPath "cms_skeleton.txt"
$IndexFile = Join-Path -Path $ContentRoot -ChildPath "index.html"
$AllPostsFile = Join-Path -Path $ContentRoot -ChildPath "all_posts.html"
$AllTagsFile = Join-Path -Path $ContentRoot -ChildPath "all_tags.html"

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
        [Parameter(Mandatory=$true)]
        [string]$EditFilePathParameter
    )
    Write-Verbose "Invoke-Edit started for parameter: $EditFilePathParameter"

    # 1. Path Resolution
    $ResolvedEditPath = $EditFilePathParameter
    if (-not ([System.IO.Path]::IsPathRooted($ResolvedEditPath))) {
        Write-Verbose "Provided path '$ResolvedEditPath' is relative. Resolving against ContentRoot: $ContentRoot"
        $ResolvedEditPath = Join-Path -Path $ContentRoot -ChildPath $ResolvedEditPath
    }
    
    # Attempt to get full path and verify existence as a file
    try {
        # Resolve-Path will error if the path doesn't exist, which is desired here.
        $ResolvedEditPath = (Resolve-Path $ResolvedEditPath -ErrorAction Stop).Path 
        Write-Verbose "Path resolved to: $ResolvedEditPath"
        if (-not (Test-Path $ResolvedEditPath -PathType Leaf)) { # Should be redundant if Resolve-Path worked for a file
            Write-Error "File not found or is not a file: $ResolvedEditPath" # Should be caught by Resolve-Path generally
            return
        }
    } catch {
        Write-Error "Error resolving or accessing file path '$EditFilePathParameter': $($_.Exception.Message)"
        return
    }
    
    Write-Host "Attempting to edit file: $ResolvedEditPath"

    # 2. Editor Launch
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

        } catch {
            Write-Error "Failed to create new post from skeleton at $ResolvedPostHtmRawPath: $($_.Exception.Message)"
            return # Critical failure for this operation
        }
    } else {
        Write-Host "Processing existing post: $ResolvedPostHtmRawPath"
    }

    # 3. Determine Output Path
    $OutputFileName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedPostHtmRawPath) + ".html"
    $OutputFilePath = Join-Path -Path (Split-Path -Path $ResolvedPostHtmRawPath) -ChildPath $OutputFileName
    Write-Verbose "Output HTML file will be: $OutputFilePath"

    # 4. Process the Post
    $Timestamp = (Get-Item $ResolvedPostHtmRawPath).LastWriteTime # Works for existing or newly created file
    Write-Verbose "Timestamp for post $ResolvedPostHtmRawPath is $Timestamp"

    # New-BlogPostHtml handles its own success/error messages.
    New-BlogPostHtml -SourceFilePath $ResolvedPostHtmRawPath -OutputFilePath $OutputFilePath -Timestamp $Timestamp
    
    # Check if HTML was actually generated before updating indexes
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
        if ($PSBoundParameters.ContainsKey('EditHtmRawPathParameter')) { # Check preferred name first
            Invoke-Edit -EditFilePathParameter $EditHtmRawPathParameter
        } elseif ($PSBoundParameters.ContainsKey('EditFilePath')) { # Check alias
            Invoke-Edit -EditFilePathParameter $EditFilePath
        }
        else {
            Write-Error "The 'edit' command requires the -EditHtmRawPathParameter (or -EditFilePath) to be specified."
        }
    }
    default {
        Write-Host "Unknown command: $Command"
    }
}
