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

if len(argv) != 5:
	print("Usage: --input IN --output OUT")
	exit()
else:
	fname_in = argv[2]
	fname_out = argv[4]

owlDict = {}

with open(fname_in) as f:
	content = f.readlines()
	for line in content:
		stripped_line = line.rstrip()
		if "hasExactSynonym" not in stripped_line:
			continue
		if "UBERON_" not in stripped_line:
			continue
		words1 = re.split(r'(")', stripped_line)
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

with open(fname_out, "w") as f_out:
	for key,value in sorted(owlDict.items()):
		f_out.write(key)
		f_out.write(" ")
		f_out.write(value)
		f_out.write("\n")
	
f_out.close()
