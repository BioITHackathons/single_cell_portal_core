# -*- coding: utf-8 -*-
"""
Created on Mon May 14 08:10:43 2018

@author: Asya
"""

from nltk import word_tokenize
from nltk.text import Text 
import json
import sys
from tkinter.filedialog import askopenfilename
from tkinter.filedialog import asksaveasfilename

# import nltk
#nltk.download() # download datasets
 
in_file = askopenfilename(initialdir="/", title="Select file", filetypes=(("text files", "*.txt"), ("all files","*.*")))
input_file = open(in_file, 'r')

#file = open('data_file.txt')

data = input_file.read()

tokens = word_tokenize(data)
text = Text(tokens)

#search = text.findall(r"<.*><.*><typhus>") 

with open("diseases.json") as json_file:
    json_data = json.load(json_file)
    
    search_token = json_data['name']

    dict_tokens = word_tokenize(search_token)    
    dict_token = Text(dict_tokens)  
#print(dict_token)
    
out_file = asksaveasfilename(initialdir="/", title="Select file", filetypes=(("text files", "*.txt"), ("all files","*.*")))
output_file = open(out_file, 'w')

tmpout = sys.stdout
sys.stdout = output_file
 
for i in dict_token:    
        concord = text.concordance(i)   
        search_token = text.findall(r"<.*><.*><"+i+">") 
        
input_file.close()
json_file.close()
output_file.close()
