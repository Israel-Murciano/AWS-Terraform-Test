import json
from datetime import datetime

date = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def lambda_handler(event, context):
    # TODO implement
    return {
        'Time': date
    }