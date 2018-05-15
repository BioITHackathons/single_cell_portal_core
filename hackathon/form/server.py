import logging

from flask import Flask
from flask import render_template
from flask import request
from flask.json import jsonify

logging.basicConfig(level='INFO')
L = logging.getLogger(__name__)

app = Flask(__name__)

ORGANISMS = {
    'someval1': 'display name',
    'someval2': 'display name 2',
}


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
