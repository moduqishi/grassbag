import requests

def get_access_token(username):
    data = {'username': {username},'password': 'rKu1/348LvKp0rsVC06eCA=='}
    headers = {'Authorization': 'Basic c3R1ZGVudDpzdHVkZW50', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.post('https://www.wtjy.com/auth/oauth/token?grant_type=password', headers=headers, data=data)
    response.raise_for_status()  # 检查请求是否成功
    json_response = response.json()
    return json_response['access_token']

def get_answer_paper(username, id, studentId, subjectId):
    access_token = get_access_token(username)  # 每次调用时获取新的访问令牌
    url = "https://www.wtjy.com/report/statappstudentreport/getanswerpaper/v2"
    params = {'id': id, 'studentId': studentId, 'subjectId': subjectId}
    headers = {'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.get(url, headers=headers, params=params)
    response.raise_for_status()  # 检查请求是否成功
    print(response.json())
    json_response = response.json()
    return json_response['data']['answerSheetUrl']
