import sys
import requests
from bs4 import BeautifulSoup

def get_daily_profit(crypto, crypto_ticker, hashrate, power, miner_fee, pool_fee):

	print("------------------------------------------------------------------------------------------------")
	print(f"crypto: {crypto}, hashrate: {hashrate}, power: {power}, miner fee: {miner_fee}, pool fee: {pool_fee}")

    # Get the profit per day in the cryptocurrency
	profit_per_day = get_profit_in_cryptocurrency(crypto_ticker, hashrate, power, miner_fee, pool_fee)

    # Get the price of the cryptocurrency in BTC from CoinGecko
	price_in_btc = get_price_data(crypto, crypto_ticker)

    # Calculate the profit in BTC
	profit_in_btc = profit_per_day * price_in_btc

	print(f"get_daily_profit = BTC {profit_in_btc:.8f}")

	return profit_in_btc

def get_profit_in_cryptocurrency(crypto_ticker, hashrate, power, miner_fee, pool_fee):

    # Build the URL for the hashrate.io calculator with the given parameters
	url = f'https://hashrate.no/coins/{crypto_ticker.upper()}/calculator'

	# Send a GET request to the URL and parse the HTML with BeautifulSoup
	response = requests.get(url)
	soup = BeautifulSoup(response.content, 'html.parser')
	
	# Set the values for the input elements
	payload = f'hashrate={hashrate}&watts={power}&minerFee={miner_fee}&poolFee={pool_fee}&update=Calculate'

	# Submit the form with the filled-in values and parse the response with BeautifulSoup
	response = requests.post(url, headers={'Content-type': 'application/x-www-form-urlencoded'}, data=payload)
	soup = BeautifulSoup(response.content, 'html.parser')

	# Find the profit element on the page and extract the daily profit text
	profit_element = soup.find('div', {'class': 'contentHeader'}, string='Results').find_parent()
	profit_element = profit_element.find('span', string='Profits').find_parent()
	profit_element = profit_element.find_all('b')[1]
	
	# Get the element text value
	profit_text = profit_element.text.strip().split()[0];

	# Parse the daily profit text as a float and print it to the console
	profit = float(profit_text)

	print(f"get_profit_in_cryptocurrency = {crypto_ticker.upper()} {profit:.2f}")

	return profit

def get_price_data(crypto, crypto_ticker):

    # Build the URL for the coingecko.com with the given parameters
	url = f'https://www.coingecko.com/en/coins/{crypto.lower()}/btc'

	# Set cookies and headers, otherwise CloudFlare will block the request
	cookies = {"_session_id": "5e56acf9d0f4ff1b5d321b5247cd7819", "cf_clearance": "TH5NAcNlzM1BFBFQRl4BcodFS7YmRZ02On8BZQ9q8P8-1679326245-0-160"}
	headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36 Edg/110.0.1587.57"}

	# Send a GET request to the URL and parse the HTML with BeautifulSoup
	response = requests.get(url, headers=headers, cookies=cookies)

	soup = BeautifulSoup(response.content, 'html.parser')

	# Find the price element on the page and extract the daily price text
	price_element = soup.find('span', attrs={'data-coin-symbol': crypto_ticker.lower()})

	# Get the element text value
	price_text = price_element.get('data-price-btc');

	# Parse the daily price text as a float and print it to the console
	price = float(price_text)

	print(f"get_price_data = BTC {price:.12f}")

	return price


args = sys.argv + [None] * (7 - len(sys.argv))

# file, crypto, crypto_ticker, hashrate, power, miner_fee, pool_fee = args
# crypto = crypto or "NEXA"
# crypto_ticker = crypto_ticker or "NEXA"
# hashrate = hashrate or 100
# power = power or 0
# miner_fee = miner_fee or 2
# pool_fee = pool_fee or 1

free_power = [
	["FLUX", "FLUX", 62, 0, 2, 1], 
	["KASPA", "KAS", 567, 0, 2, 1], 
	["NEXA", "NEXA", 70.4, 0, 2, 1], 
	["DYNEX", "DNX", 886, 0, 2, 1],
]

paid_power = [
	["FLUX", "FLUX", 62, 105, 2, 1], 
	["KASPA", "KAS", 567, 82, 2, 1], 
	["NEXA", "NEXA", 70.4, 109, 2, 1], 
	["DYNEX", "DNX", 886, 61, 2, 1],
]

settings = paid_power if args[1] == "paid" else free_power

profits = []

for algo in settings:
	profits.append(get_daily_profit(*algo))

print()

for profit in profits:
	print(f"{profit:.12f}")

print()
