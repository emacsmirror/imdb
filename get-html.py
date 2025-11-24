#!/usr/bin/python3

import time
import random
import json
import sys
import os
import pickle

from selenium import webdriver
from selenium.webdriver.support.ui import WebDriverWait
from selenium.common.exceptions import NoSuchElementException
from selenium.webdriver.common.by import By

# other includes
from selenium.webdriver.chrome.service import Service as ChromeService

# set the to used driver, here as example for the chrome-driver
service = ChromeService(executable_path="/usr/bin/chromedriver")

# Open Crome
chrome_options = webdriver.ChromeOptions()
prefs = {"profile.default_content_setting_values.notifications" : 2}
chrome_options.add_experimental_option("prefs", prefs)
chrome_options.add_argument("--disable-notifications")
chrome_options.add_argument(f'--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36')
chrome_options.add_argument("--headless")
chrome_options.add_argument("--disable-dev-shm-usage");
#chrome_options.add_argument('--no-sandbox')
chrome_options.add_experimental_option('prefs', {'intl.accept_languages': 'no'})

# give the chosen driver as option to the intatioation of Chrome()
driver = webdriver.Chrome(options = chrome_options, service = service)

from selenium import webdriver
from selenium.webdriver.chrome.options import Options

def save_cookies():
    pickle.dump(driver.get_cookies() , open(selenium_cookie_file,"wb"))

def load_cookies():
    if os.path.exists(selenium_cookie_file) and os.path.isfile(selenium_cookie_file):
        cookies = pickle.load(open(selenium_cookie_file, "rb"))

        # Enables network tracking so we may use Network.setCookie method
        driver.execute_cdp_cmd('Network.enable', {})

        # Iterate through pickle dict and add all the cookies
        for cookie in cookies:
            # Fix issue Chrome exports 'expiry' key but expects
            # 'expire' on import
            if 'expiry' in cookie:
                cookie['expires'] = cookie['expiry']
                del cookie['expiry']

            # Replace domain 'apple.com' with 'microsoft.com' cookies
            cookie['domain'] = cookie['domain'].replace('apple.com', 'microsoft.com')

            # Set the actual cookie
            driver.execute_cdp_cmd('Network.setCookie', cookie)

        # Disable network tracking
        driver.execute_cdp_cmd('Network.disable', {})
        return 1

    return 0

# Minimal settings
selenium_cookie_file = 'imdb.pickle'

load_cookies()
driver.get(sys.argv[1])

#time.sleep(6)

html = driver.execute_script("return document.body.innerHTML;")
with open("/tmp/imdb.html", "w") as f:
    f.write(html)

save_cookies()

driver.quit()
