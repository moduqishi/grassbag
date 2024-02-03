import requests
from Crypto.Cipher import AES
from base64 import b64encode

def password_encode(plain_text):
    def zero_padding(data, block_size):
        pad_len = block_size - (len(data) % block_size)
        padding = b'\x00' * pad_len
        return data + padding

    def aes_cbc_encrypt(plain_text, key, iv):
        cipher = AES.new(key, AES.MODE_CBC, iv)
        cipher_text = cipher.encrypt(zero_padding(plain_text, AES.block_size))
        return b64encode(cipher_text).decode('utf-8')  # 将字节串转换为字符串

    key = b'pigxpigxpigxpigx'  # 密钥
    iv = b'pigxpigxpigxpigx'  # 偏移量
    plain_text = plain_text.encode()  # 将字符串转换为字节串

    encodedpassword = aes_cbc_encrypt(plain_text, key, iv)
    return encodedpassword

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
