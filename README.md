## shellCMS_bulma

shellCMS_bulma is a static site generator Content Management System (CMS) based on the original shellCMS by Barry Kauler, with several modifications to support modern web development practices.

This repository is a fork of the [shellCMS](https://github.com/bkauler/woofq/tree/main/easyos/easy-code/rootfs-skeleton/usr/local/shellcms) project, developed by [Barry Kauler](https://bkhome.org/shellcms/index.html) and based on the [bashblog](https://github.com/cfenollosa/bashblog) project.

### Modifications

The modifications included shellCMS_bulma include:

    The bash file has been renamed to shellcms_b
    Internal classes have been modified to work with the Bulma CSS framework
    Added support for page SVG icons
    The option to have a SVG-picture banner instead of a top-banner.png
    Custom posts with responsive content while keeping all the benefits from the original shellCMS
    
Besides we have also the original benefits of shellCMS

    Scales efficiently to large sites
    Completely static HTML pages
    Create and edit pages with WYSIWYG HTML editor
    Any number of shellCMS_b installations on the same site
    Documentation and blog modes
    ShellCMS_b is a small bash shell script
    Develop locally, upload with rsync
    Extremely easy to use
    Optional Disqus and Twitter blog comments
    Supports Bulma CSS framework
    Supports page SVG icons
    Supports custom SVG picture banners

### Usage

    Download or clone the repository.
    Modify the config.conf file to customize the site settings, such as the site name and description, banner, and social media links.
    Place your custom SVG picture banner in the images0 folder, and edit the script to replace both your blog title and your short description.
    Place your page SVG icons in the icons folder.
    Although the use a WYSIWYG HTML editor, such as SeaMonkey Composer, to create and edit pages is supported to have better control of changes a tag based editor such as geany, vscode, helix is recommended.
    To publish your site, run the shellcms_b script in the root folder of your site. The script generates the static HTML pages, which you can upload to your web server using rsync or uploading manually your files.

Advantages of a static site

    Very secure
    Very low server load
    Very fast page loading
    Site "already archived"

As there is no database, your site is "already archived" on your local PC. You can easily move your site to another remote host by uploading the files to it.

### Requirements

ShellCMS_b runs on any operating system that can run bash. Almost all Linux distributions come with bash preinstalled. Mac also supports bash, but it is not tested. If you are a Windows user, you can boot up a Linux distribution from a USB flash drive (for now). We recommend Puppy Linux or EasyOS, which come with SeaMonkey pre-installed. Alternatively, you can use other WYSIWYG HTML editors or a text editor.


## License

This project is licensed under the terms of the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for more information.

## Acknowledgments

We would like to thank the original authors of shellCMS, Barry Kauler author of the shellCMS and the bashblog project authors as they are the origin of the project idea, and also for their valuable contributions to this project.

### Documentation

Please refer to the original documentation for more information on using [shellCMS](https://github.com/bkauler/woofq/tree/main/easyos/easy-code/rootfs-skeleton/usr/local/shellcms).

Please also refer to the original documentation for more information on using [bulma css framework](https://bulma.io/documentation/) .

##Roadmap
    
    Allow to edit variables of the blog title and subtitle, banner svg file from the config file
    Tie shellCMS_bulma to a fixed version of bulma css to avoid breaking websites.
    Port shellCMS_bulma to windows to work with powershell.


### Credits

    Barry Kauler for creating the original shellCMS
    Andres Hernandez for modifying shellCMS to create shellCMS_b.
