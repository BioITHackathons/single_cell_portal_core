from flask import Flask
from flask import render_template

app = Flask(__name__)

ORGANISMS = {
    'someval1': 'display name',
    'someval2': 'display name 2',
}


@app.route("/")
def root():
    return render_template("form.html")
