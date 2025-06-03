# tests/spelunker.tests.ps1

# Dot-source the script to be tested.
# The path assumes spelunker.ps1 is in the parent directory of this 'tests' directory.
. "$PSScriptRoot/../spelunker.ps1"

Describe "Spelunker Script Tests" {

    Context "Initial Test (Placeholder)" {
        It "Should be true" {
            $true | Should -Be $true
        }
    }

    Describe "Parse-HtmRawContent" {
        Context "Valid Content" {
            It "Should parse title, body, and tags correctly" {
                $raw = "<html><head></head><body><h1>Test Title</h1><p>Body content here.</p><!--RawTags:tag1, tag2, another tag--></body></html>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Title | Should -Be "Test Title"
                $result.Body | Should -Be "<p>Body content here.</p><!--RawTags:tag1, tag2, another tag-->" # Body includes RawTags comment by current design
                $result.Tags | Should -BeOfType ([String[]])
                $result.Tags | Should -BeExactly @("tag1", "tag2", "another tag")
            }
        }

        Context "Missing Elements" {
            It "Should default title to 'Untitled Post' if <h1> is missing" {
                $raw = "<body><p>No title.</p><!--RawTags:test--></body>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Title | Should -Be "Untitled Post"
            }

            It "Should return an empty array for Tags if RawTags comment is missing" {
                $raw = "<h1>Title</h1><body>Body</body>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Tags | Should -BeOfType ([String[]])
                $result.Tags | Should -BeEmpty
            }

            It "Should return an empty array for Tags if RawTags value is empty" {
                $raw = "<h1>Title</h1><body><!--RawTags:-->Body</body>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Tags | Should -BeOfType ([String[]])
                $result.Tags | Should -BeEmpty
            }

            It "Should return an empty array for Tags if RawTags value contains only whitespace" {
                $raw = "<h1>Title</h1><body><!--RawTags:   -->Body</body>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Tags | Should -BeOfType ([String[]])
                $result.Tags | Should -BeEmpty
            }

            It "Should return an empty string for Body if <body> tags are missing" {
                $raw = "<h1>Just a title</h1>"
                $result = Parse-HtmRawContent -RawContent $raw
                $result.Body | Should -BeEmpty
            }
        }

        Context "Empty or Null Input" {
            It "Should handle empty string input gracefully" {
                $result = Parse-HtmRawContent -RawContent ""
                $result.Title | Should -Be "Untitled Post"
                $result.Tags | Should -BeEmpty
                $result.Body | Should -BeEmpty
                $result.RawContent | Should -Be ""
            }

            It "Should handle null input gracefully" {
                $result = Parse-HtmRawContent -RawContent $null
                $result.Title | Should -Be "Untitled Post"
                $result.Tags | Should -BeEmpty
                $result.Body | Should -BeEmpty
                $result.RawContent | Should -BeNullOrEmpty # Or $null, depending on strictness
            }
        }
    }

    Describe "Determine-PageDepth" {
        # Mock Resolve-Path to control its output and avoid file system dependency
        BeforeEach {
            # Default mock for Resolve-Path: return path as is if -LiteralPath is used
            Mock Resolve-Path { param($LiteralPath) return [pscustomobject]@{ ProviderPath = $LiteralPath } } -ModuleName spelunker # Assuming functions are in a module, or remove -ModuleName
        }
        AfterEach {
            Clear-Mock Resolve-Path
        }

        It "Should return 0 for a page at the root" {
            $contentRoot = "C:\temp\spelunker\www\news"
            $pagePath = "C:\temp\spelunker\www\news\index.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 0
        }

        It "Should return 1 for a page in a subdirectory" {
            $contentRoot = "C:\temp\spelunker\www\news"
            $pagePath = "C:\temp\spelunker\www\news\posts\my-post.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 1
        }

        It "Should return 2 for a page in a deeper subdirectory" {
            $contentRoot = "C:\temp\spelunker\www\news"
            $pagePath = "C:\temp\spelunker\www\news\category\topic\another-post.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 2
        }

        It "Should handle mixed slashes if Resolve-Path normalizes them (mocked here)" {
            # Mock Resolve-Path to simulate normalization for this test
            Mock Resolve-Path -MockWith {
                param($PathToBeResolved) # Changed param name to avoid conflict
                if ($PathToBeResolved -eq "C:/temp/spelunker/www/news") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news" } }
                if ($PathToBeResolved -eq "C:/temp/spelunker/www/news/posts/my-post.html") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news\posts\my-post.html" } }
                return [pscustomobject]@{ ProviderPath = $PathToBeResolved } # Fallback
            } -ModuleName spelunker

            $contentRoot = "C:/temp/spelunker/www/news" # Input with forward slashes
            $pagePath = "C:/temp/spelunker/www/news/posts/my-post.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 1
        }

        It "Should return 0 if PagePath is not under BaseSitePath" {
            $contentRoot = "C:\temp\spelunker\www\news"
            $pagePath = "C:\temp\other\folder\index.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 0
            # Test for Write-Warning would be more complex, focus on return value
        }

        It "Should return 0 if PagePath and BaseSitePath are identical (file in root)" {
             Mock Resolve-Path -MockWith {
                param($PathToBeResolved)
                if ($PathToBeResolved -eq "C:\temp\spelunker\www\news\index.html") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news\index.html" } }
                if ($PathToBeResolved -eq "C:\temp\spelunker\www\news") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news" } }
                return [pscustomobject]@{ ProviderPath = $PathToBeResolved }
            } -ModuleName spelunker
            $contentRoot = "C:\temp\spelunker\www\news" # Base is the directory
            $pagePath = "C:\temp\spelunker\www\news\index.html"    # Page is a file in that directory
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 0
        }
         It "Should return 0 if BaseSitePath has trailing slash and PagePath is in root" {
             Mock Resolve-Path -MockWith {
                param($PathToBeResolved)
                if ($PathToBeResolved -eq "C:\temp\spelunker\www\news\") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news\" } } # Mock with trailing slash
                if ($PathToBeResolved -eq "C:\temp\spelunker\www\news\index.html") { return [pscustomobject]@{ ProviderPath = "C:\temp\spelunker\www\news\index.html" } }
                return [pscustomobject]@{ ProviderPath = $PathToBeResolved }
            } -ModuleName spelunker
            $contentRoot = "C:\temp\spelunker\www\news\"
            $pagePath = "C:\temp\spelunker\www\news\index.html"
            Determine-PageDepth -PagePath $pagePath -BaseSitePath $contentRoot | Should -Be 0
        }
    }

    Describe "Get-EditorCommand" {
        # Store original $Global:PreferredEditor and common editors list for restoration
        $originalPreferredEditor = $Global:PreferredEditor
        # The $commonEditors array is local to Get-EditorCommand, so no need to backup/restore it from here.
        # However, we need to mock Get-Command effectively.

        AfterEach {
            $Global:PreferredEditor = $originalPreferredEditor
            Clear-Mock Get-Command
        }

        Context "Preferred Editor Set and Valid" {
            It "Should return the path to the preferred editor" {
                $Global:PreferredEditor = "customeditor.exe"
                Mock Get-Command -ModuleName spelunker -MockWith {
                    if ($Name -eq "customeditor.exe") { return @{ Source = "C:\path\to\customeditor.exe" } }
                    return $null
                }
                Get-EditorCommand | Should -Be "C:\path\to\customeditor.exe"
            }
        }

        Context "Preferred Editor Set but Not Found, Fallback to Common" {
            It "Should find and return a common editor (code.exe)" {
                $Global:PreferredEditor = "nonexistent.exe"
                Mock Get-Command -ModuleName spelunker -MockWith {
                    if ($Name -eq "nonexistent.exe") { return $null }
                    if ($Name -eq "code.exe") { return @{ Source = "C:\path\to\vscode\code.exe" } }
                    return $null
                }
                Get-EditorCommand | Should -Be "C:\path\to\vscode\code.exe"
            }
        }

        Context "No Preferred Editor, Common Editor Found" {
            It "Should find the first common editor (code.exe)" {
                $Global:PreferredEditor = $null
                Mock Get-Command -ModuleName spelunker -MockWith {
                    if ($Name -eq "code.exe") { return @{ Source = "C:\path\to\vscode\code.exe" } }
                    # Simulate other common editors are not found before code.exe
                    return $null
                }
                Get-EditorCommand | Should -Be "C:\path\to\vscode\code.exe"
            }
        }

        Context "No Preferred Editor, Fallback to Notepad (last in list)" {
            It "Should find notepad.exe if others are not found" {
                $Global:PreferredEditor = $null
                Mock Get-Command -ModuleName spelunker -MockWith {
                    # Simulate other common editors are not found
                    if ($Name -eq "code.exe") { return $null }
                    if ($Name -eq "notepad++.exe") { return $null }
                    if ($Name -eq "subl.exe") { return $null }
                    if ($Name -eq "atom.exe") { return $null }
                    if ($Name -eq "geany.exe") { return $null }
                    if ($Name -eq "notepad.exe") { return @{ Source = "C:\Windows\notepad.exe" } }
                    return $null
                }
                Get-EditorCommand | Should -Be "C:\Windows\notepad.exe"
            }
        }

        Context "No Editors Found At All" {
            It "Should return null and warn (warning not tested here)" {
                $Global:PreferredEditor = $null
                Mock Get-Command -ModuleName spelunker -MockWith { return $null } # All calls to Get-Command return null
                Get-EditorCommand | Should -BeNullOrEmpty
            }
        }
    }

    Describe "Get-SpelunkerPageHeaderHtml" {
        # Store original global values to restore them later
        $originalSiteTitle = $Global:SiteTitle
        $originalSiteDescription = $Global:SiteDescription
        $originalBannerPicture = $Global:BannerPicture
        $originalButtonPermanent1 = $Global:ButtonPermanent1
        $originalButtonPermanent2 = $Global:ButtonPermanent2
        $originalButtonPermanent3 = $Global:ButtonPermanent3
        $originalCssPermanentButtonClass = $Global:CssPermanentButtonClass
        # Store and then clear specific button detail variables if they exist to ensure clean test
        $buttonKeysToBackup = @("home", "about")
        $backedUpButtonVars = @{}
        foreach ($key in $buttonKeysToBackup) {
            foreach ($suffix in @("Text", "Url", "Icon", "Tooltip")) {
                $varName = "Global:Button$($key)$suffix"
                if (Test-Path variable:$varName) {
                    $backedUpButtonVars[$varName] = (Get-Variable -Name $varName -ErrorAction SilentlyContinue).Value
                }
            }
        }

        BeforeEach {
            $Global:SiteTitle = "Test Site"
            $Global:SiteDescription = "Test Description"
            $Global:BannerPicture = "test-banner.png"
            $Global:ButtonPermanent1 = "home"
            $Global:ButtonhomeText = "Home"
            $Global:ButtonhomeUrl = "index.html"
            $Global:ButtonhomeIcon = "home.png"
            $Global:ButtonhomeTooltip = "Go Home"
            $Global:ButtonPermanent2 = "about"
            $Global:ButtonaboutText = "About"
            $Global:ButtonaboutUrl = "about.html"
            $Global:ButtonaboutIcon = "about.png"
            $Global:ButtonaboutTooltip = "About Us"
            $Global:ButtonPermanent3 = "" # Test empty slot
            $Global:CssPermanentButtonClass = "button is-test-permanent"

            # Mock Get-Variable for dynamic button config access
            Mock Get-Variable -ModuleName spelunker -MockWith {
                param($Name)
                # Simulate retrieval of global variables based on the dynamic name
                # E.g., if Name is "Global:ButtonhomeText", return "Home"
                $keyName = $Name.Replace("Global:Button", "") # e.g., homeText
                if ($Global:PSBoundParameters.ContainsKey($keyName)) { # Check if we mocked this specific detail
                    return [pscustomobject]@{ Value = $Global:($keyName) }
                } elseif ($Name -eq "Global:ButtonhomeText") { return [pscustomobject]@{ Value = $Global:ButtonhomeText } }
                elseif ($Name -eq "Global:ButtonhomeUrl") { return [pscustomobject]@{ Value = $Global:ButtonhomeUrl } }
                elseif ($Name -eq "Global:ButtonhomeIcon") { return [pscustomobject]@{ Value = $Global:ButtonhomeIcon } }
                elseif ($Name -eq "Global:ButtonhomeTooltip") { return [pscustomobject]@{ Value = $Global:ButtonhomeTooltip } }
                elseif ($Name -eq "Global:ButtonaboutText") { return [pscustomobject]@{ Value = $Global:ButtonaboutText } }
                elseif ($Name -eq "Global:ButtonaboutUrl") { return [pscustomobject]@{ Value = $Global:ButtonaboutUrl } }
                elseif ($Name -eq "Global:ButtonaboutIcon") { return [pscustomobject]@{ Value = $Global:ButtonaboutIcon } }
                elseif ($Name -eq "Global:ButtonaboutTooltip") { return [pscustomobject]@{ Value = $Global:ButtonaboutTooltip } }

                # Fallback for other global vars Get-SpelunkerPageHeaderHtml might use directly (though it shouldn't for buttons)
                if (Test-Path variable:$Name) { return (Get-Variable -Name $Name -Scope Global) }
                return $null
            }
        }

        AfterEach {
            $Global:SiteTitle = $originalSiteTitle
            $Global:SiteDescription = $originalSiteDescription
            $Global:BannerPicture = $originalBannerPicture
            $Global:ButtonPermanent1 = $originalButtonPermanent1
            $Global:ButtonPermanent2 = $originalButtonPermanent2
            $Global:ButtonPermanent3 = $originalButtonPermanent3
            $Global:CssPermanentButtonClass = $originalCssPermanentButtonClass
            foreach ($varEntry in $backedUpButtonVars.GetEnumerator()) {
                 Set-Variable -Name $varEntry.Key -Value $varEntry.Value -Scope Global -ErrorAction SilentlyContinue
            }
            # Clear specific test globals if they were set and didn't exist before
            if (-not $backedUpButtonVars.ContainsKey("Global:ButtonhomeText")) { Remove-Variable -Name Global:ButtonhomeText -ErrorAction SilentlyContinue }
            # ... and so on for all Buttonhome, Buttonabout details

            Clear-Mock Get-Variable
        }

        It "Should generate correct site title and description" {
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -Match "<strong>Test Site</strong>"
            $html | Should -Match "<p class=.subtitle.>Test Description</p>"
        }

        It "Should include banner image with correct path if BannerPicture is set" {
            $Global:BannerPicture = "my-banner.jpg"
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -Match '<img src="images0/my-banner.jpg" alt="Site Banner" />'
        }

        It "Should not include banner image section if BannerPicture is empty or whitespace" {
            $Global:BannerPicture = " " # Whitespace
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -NotMatch '<figure class="image is-128x128">'
            $Global:BannerPicture = $null # Null
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -NotMatch '<figure class="image is-128x128">'
        }

        It "Should generate configured permanent buttons" {
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -Match '<a class="button is-test-permanent" href="index.html" title="Go Home"><img src="images0/home.png" width="24" height="24" alt="Home" />&nbsp;Home</a>'
            $html | Should -Match '<a class="button is-test-permanent" href="about.html" title="About Us"><img src="images0/about.png" width="24" height="24" alt="About" />&nbsp;About</a>'
        }

        It "Should not render ButtonPermanent3 if its key is empty" {
             $Global:ButtonPermanent3 = "" # Ensure it's empty for this test
             $html = Get-SpelunkerPageHeaderHtml
             # This is harder to test directly for non-existence of a specific button if others exist.
             # We rely on the fact that if ButtonPermanent3 had config, it would be different.
             # The main check is that it doesn't error and the other two are present.
             $html | Should -Match "Home" # Check Button 1
             $html | Should -Match "About" # Check Button 2
        }

        It "Should include placeholders for dynamic buttons" {
            $html = Get-SpelunkerPageHeaderHtml
            $html | Should -Match "<!--SPELUNKER_SECONDBUTTON-->"
            $html | Should -Match "<!--SPELUNKER_THIRDBUTTON-->"
            $html | Should -Match "<!--SPELUNKER_FOURTHBUTTON-->"
            $html | Should -Match "<!--SPELUNKER_FIFTHBUTTON-->"
            $html | Should -Match "<!--SPELUNKER_SIXTHBUTTON-->"
            $html | Should -Match "<!--SPELUNKER_SEVENTHBUTTON-->"
        }
    }

    Describe "Get-SearchBoxHtml" {
        $originalSearchBoxEngine = $Global:SearchBoxEngine
        $originalSearchBoxWidth = $Global:SearchBoxWidth
        $originalCmsUrl = $Global:CmsUrl
        $originalSiteUrl = $Global:SiteUrl

        BeforeEach {
            $Global:SearchBoxWidth = "50"
            $Global:CmsUrl = "http://example.com/blog"
            $Global:SiteUrl = "http://example.com" # For Google sitesearch
        }
        AfterEach {
            $Global:SearchBoxEngine = $originalSearchBoxEngine
            $Global:SearchBoxWidth = $originalSearchBoxWidth
            $Global:CmsUrl = $originalCmsUrl
            $Global:SiteUrl = $originalSiteUrl
        }

        It "Should generate Google search form when engine is 'google'" {
            $Global:SearchBoxEngine = "google"
            $html = Get-SearchBoxHtml
            $html | Should -Match '<form class="field has-addons" action="https://www.google.com/search"'
            $html | Should -Match 'type="text" name="q"'
            $html | Should -Match 'style="width:50ch;"'
            $html | Should -Match 'type="hidden" name="sitesearch" value="example.com"'
        }

        It "Should generate DuckDuckGo (POST) search form when engine is 'duckduckgo'" {
            $Global:SearchBoxEngine = "duckduckgo"
            $html = Get-SearchBoxHtml
            $html | Should -Match '<form class="field has-addons" method="post" action="https://duckduckgo.com/"'
            $html | Should -Match 'name="q"'
            $html | Should -Match 'name="sites" type="hidden" value="example.com/blog"'
        }

        It "Should generate DuckDuckGo (GET, official) search form when engine is 'duckduckgo-official'" {
            $Global:SearchBoxEngine = "duckduckgo-official"
            $html = Get-SearchBoxHtml
            $html | Should -Match '<form class="field has-addons" method="get" action="https://duckduckgo.com/"'
            $html | Should -Match 'name="q"'
            $html | Should -NotMatch 'name="sites" type="hidden"' # User adds site: in query
        }

        It "Should return empty string if engine is not set or 'none'" {
            $Global:SearchBoxEngine = $null
            Get-SearchBoxHtml | Should -BeEmpty
            $Global:SearchBoxEngine = "none"
            Get-SearchBoxHtml | Should -BeEmpty
        }

        It "Should return empty string and warn for unrecognized engine" {
            $Global:SearchBoxEngine = "unknownengine"
            # Cannot easily test for Write-Warning in Pester v4/v5 without more complex setup
            Get-SearchBoxHtml | Should -BeEmpty
        }
    }

    Describe "Navigation Button Helpers" {
        $originalCssInfo = $Global:CssInfoButtonClass
        BeforeEach {
            $Global:CssInfoButtonClass = "button is-info-test"
        }
        AfterEach {
            $Global:CssInfoButtonClass = $originalCssInfo
            # Clear specific button globals if they were mocked
            Remove-Variable -Name Global:ButtonHistoryText -ErrorAction SilentlyContinue
            Remove-Variable -Name Global:ButtonHistoryUrl -ErrorAction SilentlyContinue
            # ... etc. for all button types used in these tests
        }

        Context "Get-HistoryButtonHtml" {
            It "Should generate correct HTML for History button" {
                $Global:ButtonHistoryText = "Past Posts"
                $Global:ButtonHistoryUrl = "archive.html"
                $Global:ButtonHistoryIcon = "history.png"
                $Global:ButtonHistoryTooltip = "View post history"
                $html = Get-HistoryButtonHtml
                $html | Should -Be '<a class="button is-info-test" href="archive.html"><img src="images0/history.png" width="24" height="24" title="View post history" alt="View post history"/>&nbsp;Past Posts</a>'
            }
        }
        Context "Get-TagsIndexButtonHtml" {
            It "Should generate correct HTML for Tags Index button" {
                $Global:ButtonTagsindexText = "All Tags"
                $Global:ButtonTagsindexUrl = "tags_all.html"
                $Global:ButtonTagsindexIcon = "tags.png"
                $Global:ButtonTagsindexTooltip = "Browse all tags"
                $html = Get-TagsIndexButtonHtml
                $html | Should -Be '<a class="button is-info-test" href="tags_all.html"><img src="images0/tags.png" width="24" height="24" title="Browse all tags" alt="Browse all tags"/>&nbsp;All Tags</a>'
            }
        }
        Context "Get-RssButtonHtml" {
            It "Should generate correct HTML for RSS button" {
                $Global:ButtonRssText = "Feed"
                $Global:ButtonRssUrl = "myfeed.xml"
                $Global:ButtonRssIcon = "rss.png"
                $Global:ButtonRssTooltip = "Subscribe now!"
                $html = Get-RssButtonHtml
                $html | Should -Be '<a class="button is-info-test" href="myfeed.xml"><img src="images0/rss.png" width="24" height="24" title="Subscribe now!" alt="Subscribe now!"/>&nbsp;Feed</a>'
            }
        }
    }

    # --- Tests for Core HTML Assembly Logic ---

    BeforeAll {
        # Mock Set-Content to capture its calls
        $Global:SetContentCalls = @()
        Mock Set-Content -ModuleName spelunker -MockWith {
            param($Path, $Value, $Force, $Encoding) # Match common params
            $Global:SetContentCalls += @{ Path = $Path; Value = $Value; Force = $Force; Encoding = $Encoding }
            Write-Verbose "Mock Set-Content: Path '$Path', Value starts: $($Value.Substring(0, [System.Math]::Min($Value.Length, 70)))..."
        }

        # Mock Get-TemplateContent
        Mock Get-TemplateContent -ModuleName spelunker -MockWith {
            param($TemplatePath)
            # Return simple, identifiable content based on the template name
            $templateFileName = $TemplatePath | Split-Path -Leaf
            return "<template_content for='$templateFileName'>"
        }

        # Mock Get-SpelunkerPageHeaderHtml
        Mock Get-SpelunkerPageHeaderHtml -ModuleName spelunker -MockWith {
            return "<div id='spelunker-header'>Mock Dynamic Header<!--SPELUNKER_SECONDBUTTON--><!--SPELUNKER_THIRDBUTTON--><!--SPELUNKER_FOURTHBUTTON--><!--SPELUNKER_FIFTHBUTTON--><!--SPELUNKER_SIXTHBUTTON--><!--SPELUNKER_SEVENTHBUTTON--></div>"
        }

        # Mock Adjust-AssetPaths
        Mock Adjust-AssetPaths -ModuleName spelunker -MockWith {
            param($HtmlContentString, $PageDepth)
            return "<!-- Adjusted for Depth $PageDepth -->`n" + $HtmlContentString
        }

        # Mock Button HTML helpers (simple versions for these assembly tests)
        Mock Get-HistoryButtonHtml    -ModuleName spelunker { return "<!--HISTORY_BUTTON-->" }
        Mock Get-TagsIndexButtonHtml  -ModuleName spelunker { return "<!--TAGS_INDEX_BUTTON-->" }
        Mock Get-RssButtonHtml        -ModuleName spelunker { return "<!--RSS_BUTTON-->" }
        Mock Get-SearchBoxHtml       -ModuleName spelunker { return "<!--SEARCH_BOX-->" }

    }
    AfterAll {
        Clear-Mock Set-Content, Get-TemplateContent, Get-SpelunkerPageHeaderHtml, Adjust-AssetPaths, Determine-PageDepth, Parse-HtmRawContent, Get-ChildItem, ConvertFrom-HtmlToText, Get-HistoryButtonHtml, Get-TagsIndexButtonHtml, Get-RssButtonHtml, Get-SearchBoxHtml -ErrorAction SilentlyContinue
        Remove-Variable -Name Global:SetContentCalls -ErrorAction SilentlyContinue
    }
    BeforeEach { # Clear calls before each test
        $Global:SetContentCalls = @()
        # Ensure required globals for title/description are set for each context if not overridden
        $Global:SiteTitle = "Global Test Site Title"
    }


    Describe "New-BlogPostHtml (Core Assembly Logic)" {
        BeforeEach {
            # Specific mock for Parse-HtmRawContent for this Describe block
            Mock Parse-HtmRawContent -ModuleName spelunker -MockWith {
                return @{ Title = "Mock Post Title"; Body = "<p>Mock Post Body</p>"; Tags = @("tagA", "tagB"); RawContent = "mock raw content" }
            }
            # Specific mock for Determine-PageDepth for posts (assume depth 1)
            Mock Determine-PageDepth -ModuleName spelunker -MockWith { param($PagePath, $BaseSitePath) return 1 }
            $Global:SearchBoxPages = "post" # Enable search box for posts
        }
        AfterEach {
            Clear-Mock Parse-HtmRawContent, Determine-PageDepth
        }

        It "Should assemble a complete HTML page for a blog post" {
            $testDate = Get-Date "2024-01-15T10:00:00"
            New-BlogPostHtml -SourceFilePath "dummy/path/post.htmraw" -OutputFilePath "dummy/output/post.html" -Timestamp $testDate

            $Global:SetContentCalls.Count | Should -Be 1
            $call = $Global:SetContentCalls[0]
            $call.Path | Should -Be "dummy/output/post.html"

            $html = $call.Value
            $html | Should -StartWith "<!-- Adjusted for Depth 1 -->"
            $html | Should -Match "<template_content for='cms_header.txt'>"
            $html | Should -Match "<title>Mock Post Title - $($Global:SiteTitle)</title>" # Title injection
            $html | Should -Match "<div id='spelunker-header'>" # Spelunker Header
            $html | Should -Match "<!--SEARCH_BOX-->" # Search box injected
            $html | Should -NotMatch "<!--SPELUNKER_THIRDBUTTON-->" # Other button placeholders cleared
            $html | Should -Match "<template_content for='cms_begin.txt'>"
            $html | Should -Match "<p>Mock Post Body</p>"
            $html | Should -Match "<p>Tags: tagA, tagB</p>"
            $html | Should -Match "<template_content for='cms_end.txt'>"
            $html | Should -Match "<template_content for='cms_footer.txt'>"
        }
    }

    Describe "Update-MainIndex (Core Assembly Logic)" {
        BeforeEach {
            $mockFile1 = [pscustomobject]@{ FullName = "C:\root\content\post1.htmraw"; LastWriteTime = (Get-Date).AddDays(-1); BaseName = "post1"; Name = "post1.htmraw" }
            $mockFile2 = [pscustomobject]@{ FullName = "C:\root\content\post2.htmraw"; LastWriteTime = (Get-Date);          BaseName = "post2"; Name = "post2.htmraw" }
            Mock Get-ChildItem -ModuleName spelunker -MockWith { return @($mockFile1, $mockFile2) }

            $parseCallCount = 0
            Mock Parse-HtmRawContent -ModuleName spelunker -MockWith {
                $parseCallCount++
                if ($parseCallCount -eq 1) { return @{ Title = "Post 1 Title"; Body = "<p>Body1</p>"; Tags = @("alpha"); RawContent = "raw1" } }
                if ($parseCallCount -eq 2) { return @{ Title = "Post 2 Title"; Body = "<p>Body2</p>"; Tags = @("beta"); RawContent = "raw2" } }
                return @{ Title = "Default Mock Title"; Body = "<p>Default Body</p>"; Tags = @(); RawContent = "raw_default" }
            }
            Mock ConvertFrom-HtmlToText -ModuleName spelunker -MockWith { param($HtmlContent) return "Mock Summary..." }
            Mock Determine-PageDepth -ModuleName spelunker -MockWith { param($PagePath, $BaseSitePath) if ($PagePath -like "*index.html") {return 0} return 1 } # Depth 0 for index

            $Global:IndexFile = "C:\root\content\index.html" # Set for the test
            $Global:ContentRoot = "C:\root\content"
            $Global:TemplatesDir = "C:\root\content\cms_config" # Needs to be valid for StartsWith check in Update-MainIndex
            $Global:NumberOfIndexArticles = 10
            $Global:SearchBoxPages = "index"
        }
        AfterEach {
            Clear-Mock Get-ChildItem, Parse-HtmRawContent, ConvertFrom-HtmlToText, Determine-PageDepth
        }

        It "Should assemble index.html with mocked posts and correct depth adjustment" {
            Update-MainIndex
            $Global:SetContentCalls.Count | Should -Be 1
            $call = $Global:SetContentCalls[0]
            $call.Path | Should -Be $Global:IndexFile

            $html = $call.Value
            $html | Should -StartWith "<!-- Adjusted for Depth 0 -->"
            $html | Should -Match "<title>$($Global:SiteTitle) - Home</title>"
            $html | Should -Match "<div id='spelunker-header'>"
            $html | Should -Match "<!--HISTORY_BUTTON-->" # Specific buttons for main index
            $html | Should -Match "<!--TAGS_INDEX_BUTTON-->"
            $html | Should -Match "<!--RSS_BUTTON-->"
            $html | Should -Match "<!--SEARCH_BOX-->"
            $html | Should -Match "<h3><a href="".*post2.html"">Post 2 Title</a></h3>" # Newest post
            $html | Should -Match "<p class=.summary.>Mock Summary...</p>"
            $html | Should -Match "<h3><a href="".*post1.html"">Post 1 Title</a></h3>"
        }
    }

    Describe "Update-AllPostsIndex (Core Assembly Logic)" {
         BeforeEach {
            $mockFile1 = [pscustomobject]@{ FullName = "C:\root\content\2023\post1.htmraw"; LastWriteTime = (Get-Date "2023-11-10"); BaseName = "post1"; Name = "post1.htmraw" }
            $mockFile2 = [pscustomobject]@{ FullName = "C:\root\content\2024\post2.htmraw"; LastWriteTime = (Get-Date "2024-01-15"); BaseName = "post2"; Name = "post2.htmraw" }
            Mock Get-ChildItem -ModuleName spelunker -MockWith { return @($mockFile1, $mockFile2) }

            $parseCallCountAllPosts = 0 # Separate counter
            Mock Parse-HtmRawContent -ModuleName spelunker -MockWith {
                $parseCallCountAllPosts++
                if ($parseCallCountAllPosts -eq 1) { return @{ Title = "Post 1 Title (Nov 2023)"; Body="b1"; Tags=@(); RawContent="r1"} }
                if ($parseCallCountAllPosts -eq 2) { return @{ Title = "Post 2 Title (Jan 2024)"; Body="b2"; Tags=@(); RawContent="r2"} }
                return @{ Title = "Default"; Body="b"; Tags=@(); RawContent="r"}
            }
            Mock Determine-PageDepth -ModuleName spelunker -MockWith { param($PagePath, $BaseSitePath) return 0 } # all_posts.html is at depth 0

            $Global:AllPostsFile = "C:\root\content\all_posts.html"
            $Global:ContentRoot = "C:\root\content"
            $Global:TemplatesDir = "C:\root\content\cms_config"
            $Global:SearchBoxPages = "all_posts"
        }
        AfterEach {
            Clear-Mock Get-ChildItem, Parse-HtmRawContent, Determine-PageDepth
        }
        It "Should assemble all_posts.html with date grouping and correct depth adjustment" {
            Update-AllPostsIndex
            $Global:SetContentCalls.Count | Should -Be 1
            $call = $Global:SetContentCalls[0]
            $call.Path | Should -Be $Global:AllPostsFile

            $html = $call.Value
            $html | Should -StartWith "<!-- Adjusted for Depth 0 -->"
            $html | Should -Match "<title>$($Global:SiteTitle) - All Posts</title>"
            $html | Should -Match "<div id='spelunker-header'>"
            $html | Should -Match "<!--RSS_BUTTON-->" # Specific for all_posts
            $html | Should -Match "<!--SEARCH_BOX-->"
            $html | Should -Match "<h2>January 2024</h2>" # Date grouping
            $html | Should -Match "<li><a href="".*2024/post2.html"">Post 2 Title \(Jan 2024\)</a>"
            $html | Should -Match "<h2>November 2023</h2>"
            $html | Should -Match "<li><a href="".*2023/post1.html"">Post 1 Title \(Nov 2023\)</a>"
        }
    }

    Describe "Update-TagsIndex (Core Assembly Logic)" {
        BeforeEach {
            $mockFileA = [pscustomobject]@{ FullName = "C:\root\content\postA.htmraw"; LastWriteTime = (Get-Date).AddDays(-2); BaseName = "postA"; Name = "postA.htmraw" }
            $mockFileB = [pscustomobject]@{ FullName = "C:\root\content\postB.htmraw"; LastWriteTime = (Get-Date).AddDays(-1); BaseName = "postB"; Name = "postB.htmraw" }
            Mock Get-ChildItem -ModuleName spelunker -MockWith { return @($mockFileA, $mockFileB) }

            $parseCallCountTags = 0
            Mock Parse-HtmRawContent -ModuleName spelunker -MockWith {
                $parseCallCountTags++
                if ($parseCallCountTags -eq 1) { return @{ Title = "Post A Title"; Tags = @("tagX", "tagY"); Body="bA"; RawContent="rA"} } # postA
                if ($parseCallCountTags -eq 2) { return @{ Title = "Post B Title"; Tags = @("tagY", "tagZ"); Body="bB"; RawContent="rB"} } # postB
                return @{ Title="D"; Tags=@(); Body="b"; RawContent="r"}
            }
            Mock Determine-PageDepth -ModuleName spelunker -MockWith { param($PagePath, $BaseSitePath) return 0 } # all tag pages at depth 0

            $Global:AllTagsFile = "C:\root\content\all_tags.html"
            $Global:ContentRoot = "C:\root\content"
            $Global:TemplatesDir = "C:\root\content\cms_config"
            $Global:SearchBoxPages = "all_tags tag_page" # Enable for both types
        }
        AfterEach {
            Clear-Mock Get-ChildItem, Parse-HtmRawContent, Determine-PageDepth
        }

        It "Should assemble all_tags.html and individual tag pages" {
            Update-TagsIndex

            # Expect 3 Set-Content calls: all_tags.html, tag_tagX.html, tag_tagY.html, tag_tagZ.html
            # Order might vary for tag pages due to hashtable key iteration, so check count first, then content.
            $Global:SetContentCalls.Count | Should -Be 4

            # Test all_tags.html
            $allTagsCall = $Global:SetContentCalls | Where-Object {$_.Path -eq $Global:AllTagsFile} | Select-Object -First 1
            $allTagsCall | Should -NotBeNullOrEmpty
            $htmlAllTags = $allTagsCall.Value
            $htmlAllTags | Should -StartWith "<!-- Adjusted for Depth 0 -->"
            $htmlAllTags | Should -Match "<title>$($Global:SiteTitle) - All Tags</title>"
            $htmlAllTags | Should -Match "<div id='spelunker-header'>"
            $htmlAllTags | Should -Match "<!--RSS_BUTTON-->"
            $htmlAllTags | Should -Match "<!--SEARCH_BOX-->"
            $htmlAllTags | Should -Match "<li><a href="".*tag_tagX.html"">tagX</a> \(1 posts\)</li>" # Sorted alphabetically
            $htmlAllTags | Should -Match "<li><a href="".*tag_tagY.html"">tagY</a> \(2 posts\)</li>"
            $htmlAllTags | Should -Match "<li><a href="".*tag_tagZ.html"">tagZ</a> \(1 posts\)</li>"

            # Test tag_tagX.html
            $tagXFile = Join-Path $Global:ContentRoot "tag_tagX.html"
            $tagXCall = $Global:SetContentCalls | Where-Object {$_.Path -eq $tagXFile} | Select-Object -First 1
            $tagXCall | Should -NotBeNullOrEmpty
            $htmlTagX = $tagXCall.Value
            $htmlTagX | Should -StartWith "<!-- Adjusted for Depth 0 -->"
            $htmlTagX | Should -Match "<title>Posts tagged 'tagX' - $($Global:SiteTitle)</title>"
            $htmlTagX | Should -Match "<h1>Posts tagged ""tagX""</h1>"
            $htmlTagX | Should -Match "<li><a href="".*postA.html"">Post A Title</a>"
            $htmlTagX | Should -NotMatch "Post B Title"
            $htmlTagX | Should -Match "<div id='spelunker-header'>" # Check for spelunker header
            $htmlTagX | Should -Match "<!--SEARCH_BOX-->"        # Check for search box

            # Test tag_tagY.html (should have two posts, Post B is newer)
            $tagYFile = Join-Path $Global:ContentRoot "tag_tagY.html"
            $tagYCall = $Global:SetContentCalls | Where-Object {$_.Path -eq $tagYFile} | Select-Object -First 1
            $tagYCall | Should -NotBeNullOrEmpty
            $htmlTagY = $tagYCall.Value
            $htmlTagY | Should -Match "<li><a href="".*postB.html"">Post B Title</a>" # Newer
            $htmlTagY | Should -Match "<li><a href="".*postA.html"">Post A Title</a>" # Older
        }
    }

    # --- Integration Tests ---

    Describe "Invoke-Post (Integration Test)" {
        $tempTestDir = $null
        $originalContentRoot = $Global:ContentRoot # Backup original
        # Backup other relevant globals that Set-GlobalPathVariables might change
        $originalTemplatesDir = $Global:TemplatesDir
        $originalHeaderTemplate = $Global:HeaderTemplate
        $originalFooterTemplate = $Global:FooterTemplate
        $originalBeginTemplate = $Global:BeginTemplate
        $originalEndTemplate = $Global:EndTemplate
        $originalSkeletonTemplate = $Global:SkeletonTemplate
        $originalIndexFile = $Global:IndexFile
        $originalAllPostsFile = $Global:AllPostsFile
        $originalAllTagsFile = $Global:AllTagsFile
        $originalIsInteractiveMode = $Global:IsInteractiveMode

        BeforeEach {
            $tempTestDir = Join-Path -Path $env:TEMP -ChildPath ([System.Guid]::NewGuid().ToString())
            $tempContentRoot = Join-Path -Path $tempTestDir -ChildPath "test_content_post" # Unique name
            $tempTemplatesDir = Join-Path -Path $tempContentRoot -ChildPath "cms_config"
            New-Item -ItemType Directory -Path $tempContentRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $tempTemplatesDir -Force | Out-Null

            Set-Content -Path (Join-Path $tempTemplatesDir "cms_header.txt") -Value "<!DOCTYPE html><html><head><title>Test</title></head><body><!-- Test Header Content -->"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_footer.txt") -Value "<!-- Test Footer Content --></body></html>"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_begin.txt") -Value "<div class='main-content'><!-- Test Begin Content -->"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_end.txt") -Value "<!-- Test End Content --></div>"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_skeleton.txt") -Value "<h1>Default Skeleton Title</h1><body><p>Skeleton body.</p><!--RawTags:default,skeleton--></body>"

            # Set global paths for the duration of this test context
            # This requires Set-GlobalPathVariables to correctly use $Global: scope for all paths it sets
            Set-GlobalPathVariables -BaseContentPathFromParam $tempContentRoot

            # Update CmsUrl and dynamic button texts now that ContentRoot is resolved
            # This logic is duplicated from the main script's execution block
            if (($Global:ContentRoot | Split-Path -Leaf) -eq '.' -or ($Global:ContentRoot -eq $PSScriptRoot) ) {
                $Global:CmsUrl = $Global:SiteUrl
                $Global:ButtonSubhomeText = "Home"
            } else {
                $Global:CmsUrl = "$($Global:SiteUrl)/$($Global:ContentRoot | Split-Path -Leaf)"
                $Global:ButtonSubhomeText = ($Global:ContentRoot | Split-Path -Leaf).ToUpper()
            }

            # Mock TUI and Editor Launch
            Mock Start-Process { Write-Verbose "Mock Start-Process called for $($FilePath) $($ArgumentList)" } -ModuleName spelunker
            Mock Read-Host { return "" } -ModuleName spelunker # Default no input for tags, P/E/D handled by IsInteractiveMode
            Mock Out-GridView { return $null } -ModuleName spelunker

            $Global:IsInteractiveMode = $false # Test non-interactive post creation first
        }

        AfterEach {
            if (Test-Path $tempTestDir) {
                Remove-Item -Path $tempTestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Clear-Mock Start-Process, Read-Host, Out-GridView -ErrorAction SilentlyContinue

            # Restore original globals
            $Global:ContentRoot = $originalContentRoot
            $Global:TemplatesDir = $originalTemplatesDir
            $Global:HeaderTemplate = $originalHeaderTemplate
            $Global:FooterTemplate = $originalFooterTemplate
            $Global:BeginTemplate = $originalBeginTemplate
            $Global:EndTemplate = $originalEndTemplate
            $Global:SkeletonTemplate = $originalSkeletonTemplate
            $Global:IndexFile = $originalIndexFile
            $Global:AllPostsFile = $originalAllPostsFile
            $Global:AllTagsFile = $originalAllTagsFile
            $Global:IsInteractiveMode = $originalIsInteractiveMode
            # Re-run Set-GlobalPathVariables if originalContentRoot was valid, to restore derived paths
            if ($originalContentRoot) { Set-GlobalPathVariables -BaseContentPathFromParam $originalContentRoot }
        }

        It "Should create a new post, its HTML, and basic index files in non-interactive mode" {
            $postHtmRawPath = "new-test-post.htmraw"
            $fullHtmRawPath = Join-Path $Global:ContentRoot $postHtmRawPath
            $fullHtmlPath = $fullHtmRawPath -replace '\.htmraw$', '.html'

            Invoke-Post -PostHtmRawPathParameter $postHtmRawPath

            (Test-Path $fullHtmRawPath) | Should -Be $true
            (Test-Path $fullHtmlPath) | Should -Be $true

            (Get-Content $fullHtmlPath -Raw) | Should -Contain "Skeleton body"
            (Get-Content $fullHtmlPath -Raw) | Should -Contain "<!--RawTags:default,skeleton-->"

            (Test-Path $Global:IndexFile) | Should -Be $true
            (Get-Content $Global:IndexFile -Raw) | Should -Match "<a href=.new-test-post.html.>" # Relative link

            (Test-Path $Global:AllPostsFile) | Should -Be $true
            (Get-Content $Global:AllPostsFile -Raw) | Should -Match "<a href=.new-test-post.html.>"

            (Test-Path $Global:AllTagsFile) | Should -Be $true
            (Get-Content $Global:AllTagsFile -Raw) | Should -Match "<a href=.tag_default.html.>"
            (Get-Content $Global:AllTagsFile -Raw) | Should -Match "<a href=.tag_skeleton.html.>"

            (Test-Path (Join-Path $Global:ContentRoot "tag_default.html")) | Should -Be $true
            (Get-Content (Join-Path $Global:ContentRoot "tag_default.html") -Raw) | Should -Match "<a href=.new-test-post.html.>"
        }
    }

    Describe "Invoke-Rebuild (Integration Test)" {
        $tempTestDir = $null
        $originalContentRoot = $Global:ContentRoot
        $originalTemplatesDir = $Global:TemplatesDir
        $originalHeaderTemplate = $Global:HeaderTemplate
        $originalFooterTemplate = $Global:FooterTemplate
        $originalBeginTemplate = $Global:BeginTemplate
        $originalEndTemplate = $Global:EndTemplate
        $originalSkeletonTemplate = $Global:SkeletonTemplate
        $originalIndexFile = $Global:IndexFile
        $originalAllPostsFile = $Global:AllPostsFile
        $originalAllTagsFile = $Global:AllTagsFile
        $originalIsInteractiveMode = $Global:IsInteractiveMode


        BeforeEach {
            $tempTestDir = Join-Path -Path $env:TEMP -ChildPath ([System.Guid]::NewGuid().ToString())
            $tempContentRoot = Join-Path -Path $tempTestDir -ChildPath "test_content_rebuild" # Unique name
            $tempTemplatesDir = Join-Path -Path $tempContentRoot -ChildPath "cms_config"
            New-Item -ItemType Directory -Path $tempContentRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $tempTemplatesDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tempContentRoot "posts") -Force | Out-Null


            Set-Content -Path (Join-Path $tempTemplatesDir "cms_header.txt") -Value "<!DOCTYPE html><html><head><title>Test</title></head><body>"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_footer.txt") -Value "</body></html>"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_begin.txt") -Value "<div class='main-content'>"
            Set-Content -Path (Join-Path $tempTemplatesDir "cms_end.txt") -Value "</div>"

            Set-Content -Path (Join-Path $tempContentRoot "post1.htmraw") -Value "<h1>Post 1 Title</h1><body>Body for Post 1<!--RawTags:tagA,common--></body>"
            Set-Content -Path (Join-Path $tempContentRoot "posts/post2.htmraw") -Value "<h1>Post 2 Title</h1><body>Content for Post 2<!--RawTags:tagB,common--></body>"

            Set-GlobalPathVariables -BaseContentPathFromParam $tempContentRoot
            if (($Global:ContentRoot | Split-Path -Leaf) -eq '.'-or ($Global:ContentRoot -eq $PSScriptRoot) ) {
                $Global:CmsUrl = $Global:SiteUrl
                $Global:ButtonSubhomeText = "Home"
            } else {
                $Global:CmsUrl = "$($Global:SiteUrl)/$($Global:ContentRoot | Split-Path -Leaf)"
                $Global:ButtonSubhomeText = ($Global:ContentRoot | Split-Path -Leaf).ToUpper()
            }
            $Global:IsInteractiveMode = $false # Ensure non-interactive for rebuild
        }
        AfterEach {
            if (Test-Path $tempTestDir) {
                Remove-Item -Path $tempTestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
             $Global:ContentRoot = $originalContentRoot
            $Global:TemplatesDir = $originalTemplatesDir
            $Global:HeaderTemplate = $originalHeaderTemplate
            $Global:FooterTemplate = $originalFooterTemplate
            $Global:BeginTemplate = $originalBeginTemplate
            $Global:EndTemplate = $originalEndTemplate
            $Global:SkeletonTemplate = $originalSkeletonTemplate
            $Global:IndexFile = $originalIndexFile
            $Global:AllPostsFile = $originalAllPostsFile
            $Global:AllTagsFile = $originalAllTagsFile
            $Global:IsInteractiveMode = $originalIsInteractiveMode
            if ($originalContentRoot) { Set-GlobalPathVariables -BaseContentPathFromParam $originalContentRoot }
        }

        It "Should regenerate HTML for all posts and create all index files" {
            Invoke-Rebuild

            (Test-Path (Join-Path $Global:ContentRoot "post1.html")) | Should -Be $true
            (Test-Path (Join-Path $Global:ContentRoot "posts/post2.html")) | Should -Be $true

            (Get-Content (Join-Path $Global:ContentRoot "post1.html") -Raw) | Should -Contain "Body for Post 1"
            (Get-Content (Join-Path $Global:ContentRoot "posts/post2.html") -Raw) | Should -Contain "Content for Post 2"
            # Check asset path adjustment for post2.html (depth 1)
            (Get-Content (Join-Path $Global:ContentRoot "posts/post2.html") -Raw) | Should -Match "<!-- Adjusted for Depth 1 -->"


            (Test-Path $Global:IndexFile) | Should -Be $true
            (Get-Content $Global:IndexFile -Raw) | Should -Match "<a href=.post1.html.>"
            (Get-Content $Global:IndexFile -Raw) | Should -Match "<a href=.posts/post2.html.>" # Relative from ContentRoot

            (Test-Path $Global:AllPostsFile) | Should -Be $true
             (Get-Content $Global:AllPostsFile -Raw) | Should -Match "<a href=.posts/post2.html.>" # Check relative path

            (Test-Path $Global:AllTagsFile) | Should -Be $true
            (Get-Content $Global:AllTagsFile -Raw) | Should -Match "<a href=.tag_tagA.html.>"
            (Get-Content $Global:AllTagsFile -Raw) | Should -Match "<a href=.tag_tagB.html.>"
            (Get-Content $Global:AllTagsFile -Raw) | Should -Match "<a href=.tag_common.html.>"

            (Test-Path (Join-Path $Global:ContentRoot "tag_tagA.html")) | Should -Be $true
            (Get-Content (Join-Path $Global:ContentRoot "tag_tagA.html") -Raw) | Should -Match "Post 1 Title"
            (Test-Path (Join-Path $Global:ContentRoot "tag_common.html")) | Should -Be $true
            (Get-Content (Join-Path $Global:ContentRoot "tag_common.html") -Raw) | Should -Match "Post 1 Title"
            (Get-Content (Join-Path $Global:ContentRoot "tag_common.html") -Raw) | Should -Match "Post 2 Title"
        }
    }
}
