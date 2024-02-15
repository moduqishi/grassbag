import flet as ft
import grass

studentId = ''
access_token = ''

def main(page: ft.Page):

    page.scroll = True

    audio1 = ft.Audio(
        src="/ScoreTrackin'Superstar2.mp3", autoplay=True
        #src="/勇敢说不.mp3", autoplay=True
    )
    page.overlay.append(audio1)

    page.appbar = ft.AppBar(
        leading=ft.Icon(ft.icons.PALETTE),
        leading_width=40,
        title=ft.Text("大草包查成绩内测beta 0.1.1"),
        center_title=False,
        bgcolor=ft.colors.SURFACE_VARIANT,
        actions=[
            ft.IconButton(ft.icons.MUSIC_OFF, on_click=lambda _: audio1.pause()),
        ],
    )


    username_input = ft.TextField(label="用户名", hint_text="请输入用户名")
    password_input = ft.TextField(label="密码(已支持所有密码)", hint_text="请输入密码", value="123456", cursor_color="Blue")
    examId_input = ft.TextField(label="examId", hint_text="请输入examId", value="13238", cursor_color="Blue")
    studentId_input = ft.TextField(label="studentId", hint_text="请输入要查询的studentId")
    subject_input = ft.Dropdown(
        label="科目",
        hint_text="请选择科目",
        options=[
            ft.dropdown.Option(text="语文", key=1),
            ft.dropdown.Option(text="数学", key=2),
            ft.dropdown.Option(text="英语", key=3),
            ft.dropdown.Option(text="理综", key=14),
            ft.dropdown.Option(text="物理", key=8),
            ft.dropdown.Option(text="化学", key=9),
            ft.dropdown.Option(text="生物", key=7),
        ],
        value="1",
        autofocus=True,
    )

    page.add(username_input, password_input, studentId_input, examId_input, subject_input)

    def button_clicked(e):
        global access_token, studentId
        if not username_input.value:
            page.add(ft.Text("请输入用户名", color="Red"))
        elif not password_input.value:
            page.add(ft.Text("请输入密码", color="Red"))
        else:
            username = username_input.value
            password = password_input.value
            studentId = studentId_input.value
            subject = subject_input.value
            examId = examId_input.value
            tokens = grass.get_access_token(username, password)
            access_token = tokens['access_token']
            
            if not studentId_input.value:
                studentId = tokens['studentId']
                studentId_input.value = studentId
            else:
                studentId = studentId_input.value

            page.update()
            anserpaper_url = grass.get_answer_paper(access_token, examId, studentId, subject)
            papers = anserpaper_url.split("，")
            
            paperA = papers[0]
            paperB = papers[1]

            showpaperA = ft.TextField(label="A面", read_only=True, value=paperA, cursor_color="Blue")
            showpaperB = ft.TextField(label="B面", read_only=True, value=paperB, cursor_color="Blue")

            page.add(ft.Text("请复制答题卡链接在浏览器打开", color="Red"), showpaperA, showpaperB)
        
    b = ft.ElevatedButton("查成绩", on_click=button_clicked, data=0)

    page.add(b,)

ft.app(target=main)