import flet as ft
import grass

studentId = ''
access_token = ''

def main(page: ft.Page):

    page.scroll = True

    audio1 = ft.Audio(
        #src="/ScoreTrackin'Superstar2.mp3", autoplay=True
        src="/勇敢说不.mp3", autoplay=True
    )
    page.overlay.append(audio1)

    page.appbar = ft.AppBar(
        leading=ft.Icon(ft.icons.PALETTE),
        leading_width=40,
        title=ft.Text("大草包查成绩内测beta 0.0.9"),
        center_title=False,
        bgcolor=ft.colors.SURFACE_VARIANT,
        actions=[
            ft.IconButton(ft.icons.MUSIC_OFF, on_click=lambda _: audio1.pause()),
        ],
    )


    username_input = ft.TextField(label="用户名", hint_text="请输入用户名")
    password_input = ft.TextField(label="密码(已支持所有密码)", hint_text="请输入密码", value="123456", cursor_color="Blue")
    studentId_input = ft.TextField(label="studentId", hint_text="请输入要查询的studentId")
    page.add(username_input, password_input, studentId_input)

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
            tokens = grass.get_access_token(username, password)
            access_token = tokens['access_token']
            
            if not studentId_input.value:
                studentId = tokens['studentId']
                studentId_input.value = studentId
            else:
                studentId = studentId_input.value

            page.update()
            anserpaper_url = grass.get_answer_paper(access_token, 13238, studentId, 1)
            papers = anserpaper_url.split("，")
            
            paperA = papers[0]
            paperB = papers[1]

            showpaperA = ft.TextField(label="A面", read_only=True, value=paperA, cursor_color="Blue")
            showpaperB = ft.TextField(label="B面", read_only=True, value=paperB, cursor_color="Blue")

            page.add(ft.Text("请复制答题卡链接在浏览器打开", color="Red"), showpaperA, showpaperB)

            '''
            img1 = ft.Image(
                src=f"{paperA}",
                width=500,
                height=300,
                fit=ft.ImageFit.CONTAIN,
                )
            
            img2 = ft.Image(
                src=f"{paperB}",
                width=500,
                height=300,
                fit=ft.ImageFit.CONTAIN,
                )
            
            page.add(img1, img2)
            '''

        

    b = ft.ElevatedButton("查成绩", on_click=button_clicked, data=0)

    page.add(b,)



'''
    page.add(
        ft.Row(
            [
                ft.Container(
                    content=ft.Text("语文：150", color= 'Black'),
                    margin=10,
                    padding=10,
                    alignment=ft.alignment.center,
                    bgcolor=ft.colors.CYAN_200,
                    width=300,
                    height=150,
                    border_radius=10,
                ),
            ],
            alignment=ft.MainAxisAlignment.CENTER,
        ),
    )
'''

ft.app(target=main)