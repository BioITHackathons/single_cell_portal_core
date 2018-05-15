import pandas as pd
import numpy as np
pd.set_option('display.max_columns', None)
import json
import re

#how to run:

#Note: TODO the address of the dictionary file is hardcoded below, make sure to update
readDictionary = r"C:\Users\sdanesh\Documents\hackathon\taxon.txt"

#python findOrganisms.py C:\Users\sdanesh\Documents\hackathon\singleCellRepo3\hackathon\NLP\sampleInput.txt C:/sampleoutput.json





#TODO take file path for taking input 
#TODO print json to path entered for output
#!/usr/bin/python

import sys

print("Number of arguments:" + str(len(sys.argv)), "arguments.")
print ("Argument List:"+ str(sys.argv))

if(len(sys.argv) == 3): #assuming arguments are inputPath, outputPath
    with open(sys.argv[1], 'r') as content_file:
        text = content_file.read()
        print("Input File Path used = "+str(sys.argv[1]))
else:
    text = "Single nucleus RNA-seq of cell diversity in the adult mouse hippocampus. Habib N, Li Y, Heidenreich M, Swiech L, Avraham-Davidi I, Trombetta J, Hession C, Zhang F, Regev A. Div-Seq: Single-nucleus RNA-Seq reveals dynamics of rare adult newborn neurons. Science  28 Jul 2016 DOI: 10.1126/science.aad7038 Contact: naomi@broadinstitute.org Single cell RNA-Seq provides rich information about cell types and states. However, it is difficult to capture rare dynamic processes, such as adult neurogenesis, because isolation of rare neurons from adult tissue is challenging and markers for each phase are limited. Here, we develop Div-Seq, which combines scalable single-nucleus RNA-Seq (sNuc-Seq) with pulse labeling of proliferating cells by EdU to profile individual dividing cells. sNuc-Seq and Div-Seq can sensitively identify closely related hippocampal cell types and track transcriptional dynamics of newborn neurons within the adult hippocampal neurogenic niche, respectively. This study contains the sNuc-Seq analysis performed as a part of the Div-Seq method development. Using sNuc-Seq, we analyzed 1,367 single nuclei from hippocampal anatomical sub-regions (DG, CA1, CA2, and CA3) from adult mice, including enrichment of genetically-tagged lowly abundant GABAergic neurons (9). sNuc-Seq robustly generated high quality data across animal age groups (including 2 years old mice), detecting 5,100 expressed genes per nucleus on average, with comparable complexity to single neuron RNA-Seq from young mice (1, 2, 3). Analysis of sNuc-Seq data revealed distinct nuclei clusters (Fig. 1B-D shown below) corresponding to known cell types and anatomical distinctions in the hippocampus."





f = open(readDictionary, encoding = "ISO-8859-1")

stopwords = ["a", "about", "above", "above", "across", "after", "afterwards", "again", "against", "all", "almost", "alone", "along", "already", "also","although","always","am","among", "amongst", "amoungst", "amount",  "an", "and", "another", "any","anyhow","anyone","anything","anyway", "anywhere", "are", "around", "as",  "at", "back","be","became", "because","become","becomes", "becoming", "been", "before", "beforehand", "behind", "being", "below", "beside", "besides", "between", "beyond", "bill", "both", "bottom","but", "by", "call", "can", "cannot", "cant", "co", "con", "could", "couldnt", "cry", "de", "describe", "detail", "do", "done", "down", "due", "during", "each", "eg", "eight", "either", "eleven","else", "elsewhere", "empty", "enough", "etc", "even", "ever", "every", "everyone", "everything", "everywhere", "except", "few", "fifteen", "fify", "fill", "find", "fire", "first", "five", "for", "former", "formerly", "forty", "found", "four", "from", "front", "full", "further", "get", "give", "go", "had", "has", "hasnt", "have", "he", "hence", "her", "here", "hereafter", "hereby", "herein", "hereupon", "hers", "herself", "him", "himself", "his", "how", "however", "hundred", "ie", "if", "in", "inc", "indeed", "interest", "into", "is", "it", "its", "itself", "keep", "last", "latter", "latterly", "least", "less", "ltd", "made", "many", "may", "me", "meanwhile", "might", "mill", "mine", "more", "moreover", "most", "mostly", "move", "much", "must", "my", "myself", "name", "namely", "neither", "never", "nevertheless", "next", "nine", "no", "nobody", "none", "noone", "nor", "not", "nothing", "now", "nowhere", "of", "off", "often", "on", "once", "one", "only", "onto", "or", "other", "others", "otherwise", "our", "ours", "ourselves", "out", "over", "own","part", "per", "perhaps", "please", "put", "rather", "re", "same", "see", "seem", "seemed", "seeming", "seems", "serious", "several", "she", "should", "show", "side", "since", "sincere", "six", "sixty", "so", "some", "somehow", "someone", "something", "sometime", "sometimes", "somewhere", "still", "such", "system", "take", "ten", "than", "that", "the", "their", "them", "themselves", "then", "thence", "there", "thereafter", "thereby", "therefore", "therein", "thereupon", "these", "they", "thickv", "thin", "third", "this", "those", "though", "three", "through", "throughout", "thru", "thus", "to", "together", "too", "top", "toward", "towards", "twelve", "twenty", "two", "un", "under", "until", "up", "upon", "us", "very", "via", "was", "we", "well", "were", "what", "whatever", "when", "whence", "whenever", "where", "whereafter", "whereas", "whereby", "wherein", "whereupon", "wherever", "whether", "which", "while", "whither", "who", "whoever", "whole", "whom", "whose", "why", "will", "with", "within", "without", "would", "yet", "you", "your", "yours", "yourself", "yourselves", "the"]




n = 0
terms_dict = {}

for line in f:
    n += 1
    #term_to_uri[]

    if False: #remember to take the prints out if you make this false otherwise big pring out and notebook hangs
        if(n > 400):
            break
    #print(line.split())
    #splitLine = line.split("\s|;")
    splitLine = re.split("\s|;", line)
    uri = splitLine[0]
    #print("splitLine = "+str(splitLine))
    
    if(len(splitLine[1:]) > 1):
        term = " ".join(splitLine[1:])
        termAndWords = splitLine[1:]
        termAndWords.append(term)
        #print(term)
        #terms_dict[term] = uri
    
    for word in termAndWords:
        if(len(word) < 4 or (word in stopwords)): #for some reason stop words still show up so filtering them down later below
            #print(word)
            next
            
        #print(word)
        
        if word in terms_dict:
            curCount = terms_dict[word]['count']
            terms_dict[word] = {"uri": uri, "count": curCount+1}
        else:
            terms_dict[word] = {"uri": uri, "count": 1}

print("Number of terms in dictionary = "+str(len(terms_dict)))


terms_seen = []
for term in terms_dict:
    if(" "+term+" " in text):
        terms_seen.append(term)


def hasNumbers(inputString):
    return bool(re.search(r'\d', inputString))

good_terms = []
for term in terms_seen:
    if( not(term.lower() in stopwords or term == "" or hasNumbers(term) or len(term) < 4 )):
        good_terms.append(term)



outputJson = []
for word in good_terms:
    print(terms_dict[word])
    outputJson.append({"entity":word, "type":"organism", "uri":terms_dict[word]['uri']})

outputJson = json.dumps(outputJson)
print(outputJson)

if(len(sys.argv) == 3): #assuming arguments are inputPath, outputPath
    print("Writing output to "+ sys.argv[2])
    with open(sys.argv[2], 'w') as f:
        json.dump(outputJson, f)



 