import requests

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.backends import default_backend
from base64 import b64encode

def password_encode(plain_text):
    key = b'pigxpigxpigxpigx'  # 密钥
    iv = b'pigxpigxpigxpigx'  # 偏移量
    plain_text = plain_text.encode()  # 将字符串转换为字节串

    # 创建一个 AES CBC cipher
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())

    # 创建一个 encryptor
    encryptor = cipher.encryptor()

    # 计算 padding 长度
    pad_len = 16 - (len(plain_text) % 16)

    # 添加 padding
    plain_text += b'\x00' * pad_len

    # 加密
    cipher_text = encryptor.update(plain_text) + encryptor.finalize()

    return b64encode(cipher_text).decode('utf-8')  # 将字节串转换为字符串


def get_access_token(username, password):
    password = password_encode(password)
    data = {'username': {username},'password': {password}}
    headers = {'Authorization': 'Basic c3R1ZGVudDpzdHVkZW50', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.post('https://www.wtjy.com/auth/oauth/token?grant_type=password', headers=headers, data=data)
    response.raise_for_status()  # 检查请求是否成功
    json_response = response.json()
    return json_response['access_token']

def get_answer_paper(username, password, id, studentId, subjectId):
    access_token = get_access_token(username, password)  # 每次调用时获取新的访问令牌
    url = "https://www.wtjy.com/report/statappstudentreport/getanswerpaper/v2"
    params = {'id': id, 'studentId': studentId, 'subjectId': subjectId}
    headers = {'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/x-www-form-urlencoded'}
    response = requests.get(url, headers=headers, params=params)
    response.raise_for_status()  # 检查请求是否成功
    print(response.json())
    json_response = response.json()
    return json_response['data']['answerSheetUrl']

print(password_encode("123456"))