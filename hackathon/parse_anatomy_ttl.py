#!/usr/bin/env python3

""" 
Code to read in and parse some information out of a TTL file for anatomy ontologies.
Looks for a few keywords that needs to be included and produces two column output.
The URI is in the first column.  The second has a list of corresponding anatomical
terms.
Missing (good) a check that the anatomical terms are present.
"""

import re
from sys import argv

if len(argv) != 2:
	print("Please suppy input TTL file")
	exit()
else:
	fname = argv[1]

owlDict = {}

with open(fname) as f:
	content = f.readlines()
	for line in content:
		stripped_line = line.rstrip()
		if "hasExactSynonym" not in stripped_line:
			continue
		if "UBERON_" not in stripped_line:
			continue
		words1 = re.split(r'(\")', stripped_line)
		if len(words1) < 4:
			continue
		organ = words1[2]
		words3 = words1[0].split()[0].replace(">", "")
		uri = words3[1:]
		if uri not in owlDict:
			owlDict[uri] = organ
		else:
			owlDict[uri] += ";"
			owlDict[uri] += organ

for key,value in sorted(owlDict.items()):
	print(key, value)
	
