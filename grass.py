import requests
import pyaes
from base64 import b64encode

def password_encode(plain_text):
    key = b'pigxpigxpigxpigx'  # 密钥
    iv = b'pigxpigxpigxpigx'  # 初始化向量
    plain_text = plain_text.encode()  # 将字符串转换为字节串

    # 计算 padding 长度
    pad_len = 16 - (len(plain_text) % 16)

    # 添加 padding
    plain_text += b'\x00' * pad_len

    # 创建一个 AES CBC cipher
    cipher = pyaes.AESModeOfOperationCBC(key, iv)

    # 加密
    cipher_text = b"".join([cipher.encrypt(plain_text[i:i+16]) for i in range(0, len(plain_text), 16)])

    return b64encode(cipher_text).decode('utf-8')  # 将字节串转换为字符串

def get_access_token(username, password):
    global access_token, studentId
    password = password_encode(password)
    data = {'username': username,'password': password}
    headers = {'Authorization': 'Basic c3R1ZGVudDpzdHVkZW50', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.post('https://www.wtjy.com/auth/oauth/token?grant_type=password', headers=headers, data=data)
    response.raise_for_status()  # 检查请求是否成功
    json_response = response.json()
    studentId = json_response['user_info']['studentId']
    access_token = json_response['access_token']
    return {'access_token': access_token, 'studentId': studentId}

def get_answer_paper(access_token, id, studentId, subjectId):
    url = "https://www.wtjy.com/report/statappstudentreport/getanswerpaper/v2"
    params = {'id': id, 'studentId': studentId, 'subjectId': subjectId}
    headers = {'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.get(url, headers=headers, params=params)
    response.raise_for_status()  # 检查请求是否成功
    json_response = response.json()
    return json_response['data']['answerSheetUrl']

