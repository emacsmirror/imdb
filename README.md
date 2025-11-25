This is a package to query IMDB from Emacs, and also contains
imdb-mode, which uses the IMDB data dumps to display data.

Because imdb.com is behind the Amazon anti-scraping firewall, imdb.el
uses Selenium to actually fetch pages.  So for the package to work,
you need to install Selenium and Chrome.

On Debian:

# apt install python3-selenium chromium-driver

To check whether this works:

```
cd imdb.el
./get-html.py 'https://www.imdb.com/find?q=If%20Looks%20Could%20Kill&s=tt&ref_=fn_al_tt_mr' 
```

And then check whether the output looks reasonable -- if the output
contains data on "If Looks Could Kill".
