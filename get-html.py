#!/usr/bin/python3

import time
import random
import json
import sys
import os
import pickle

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait
from selenium.common.exceptions import NoSuchElementException
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.service import Service as ChromeService

selenium_cookie_file = 'imdb.pickle'
service = ChromeService(executable_path="/usr/bin/chromedriver")

# Open Crome
chrome_options = webdriver.ChromeOptions()
prefs = {"profile.default_content_setting_values.notifications" : 2}
chrome_options.add_experimental_option("prefs", prefs)
chrome_options.add_argument("--disable-notifications")
# The default User-Agent is "HeadlessChrome", which imdb.com bans.
chrome_options.add_argument(f'--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36')
chrome_options.add_argument("--headless")
chrome_options.add_argument("--disable-dev-shm-usage");
chrome_options.add_experimental_option('prefs', {'intl.accept_languages': 'no'})

# Give the chosen driver as an option to Chrome()
driver = webdriver.Chrome(options = chrome_options, service = service)

def save_cookies():
    pickle.dump(driver.get_cookies() , open(selenium_cookie_file,"wb"))

def load_cookies():
    if os.path.exists(selenium_cookie_file):
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

            # Set the actual cookie
            driver.execute_cdp_cmd('Network.setCookie', cookie)

        # Disable network tracking
        driver.execute_cdp_cmd('Network.disable', {})

load_cookies()
driver.get(sys.argv[1])
save_cookies()

print(driver.execute_script("return document.body.innerHTML;"))

driver.quit()
