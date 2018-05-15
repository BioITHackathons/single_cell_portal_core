import logging

from flask import Flask
from flask import render_template
from flask import request
from flask.json import jsonify

logging.basicConfig(level='INFO')
L = logging.getLogger(__name__)

app = Flask(__name__)

ORGANISMS = {}
# Read in taxon.txt
with open('taxon.txt', 'rb') as taxon_file:
    for line in taxon_file:
        line = line.decode('utf8').strip()
        if not line:
            continue
        url, text = line.split(maxsplit=1)
        ORGANISMS[url] = text


@app.route("/")
def root():
    return render_template("form.html")


@app.route("/organisms")
def organisms():
    query = request.args['q']
    print (query)
    result = []
    for value, name in ORGANISMS.items():
        if query in name:
            result.append({'value': value, 'text': name})
    return jsonify(result)
