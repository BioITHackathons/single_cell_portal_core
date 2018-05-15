# -*- coding: utf-8 -*-
"""
Created on Mon May 14 08:10:43 2018

@author: Asya
"""

from nltk import word_tokenize
from nltk.text import Text 
import json

# import nltk
#nltk.download() # download datasets

file = open('data_file.txt')
data = file.read()

tokens = word_tokenize(data)
text = Text(tokens)

#search = text.findall(r"<.*><.*><typhus>") 

with open("diseases.json") as json_file:
    json_data = json.load(json_file)
    
    search_token = json_data['name']

    dict_tokens = word_tokenize(search_token)    
    dict_token = Text(dict_tokens)  
    print(dict_token)
     
for i in dict_token:    
    concord = text.concordance(i) 
    search = text.findall(r"<.*><.*><"+i+">")
   
file.close()
json_file.close()