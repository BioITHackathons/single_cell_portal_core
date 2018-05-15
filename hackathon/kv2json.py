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
	

if len(argv) != 5:
	print("Usage: --input IN --output OUT")
	exit()
else:
	fname_in = argv[2]
	fname_out = argv[4]

inJson = json.load(open(fname_in))

outJsonList = []
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
	outJsonList.append(outJson)


with open(fname_out, "w") as f_out:
	json.dump(outJsonList, f_out)
	f_out.close()
