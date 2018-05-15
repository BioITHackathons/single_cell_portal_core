#!/usr/bin/env python3

"""
Takes input JSON output to produce new FAIR JSON
""" 

from sys import argv
import json

def MakeDict(oldDict):
	retDict = {}
	retDict["text"] = oldDict["entity"]
	retDict["uri"] = oldDict["uri"]
	return retDict
	

if len(argv) != 2:
	print("Please supply input JSON file")
	exit()
else:
	fname = argv[1]

inJson = json.load(open(fname))

outJson = {}

for elem in inJson:
	tempDict = MakeDict(elem)
	newElemList = [tempDict]
	if elem["type"] == "anatomy":
		outJson["organ"] = newElemList
	elif elem["type"] ==  "organism":
		outJson["genus_species"] = newElemList
	else:
		outJson[elem["type"]] = newElemList


outJsonList = [outJson]
print(outJsonList)
