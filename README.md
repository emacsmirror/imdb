This is a package to query IMDB from Emacs, and also contains
imdb-mode, which uses the IMDB data dumps to display data.

Requirements
============

Because imdb.com is behind the Amazon anti-scraping firewall, imdb.el
uses Selenium to actually fetch pages.  So for the package to work,
you need to install Selenium and Chrome and this package:

https://github.com/larsmagne/fetch-dom.el

