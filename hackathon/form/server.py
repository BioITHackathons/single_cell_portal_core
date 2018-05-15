import json
from flask import Flask
from flask import render_template
from flask import request
from flask.json import jsonify

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
    query = request.form['q']
    import IPython; IPython.embed()
    result = []
    for value, name in ORGANISMS.items():
        print (name, query)
        if query in name:
            result.append({'value': value, 'text': name})
    return jsonify(result)
