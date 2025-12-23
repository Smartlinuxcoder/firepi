# to flash to the rp2350 side of the board
from machine import UART, Pin
import time


uart = UART(0, baudrate=115200, tx=Pin(12), rx=Pin(13))

led = Pin("LED", Pin.OUT)


def send_command(cmd):
    uart.write(cmd.encode('utf-8') + b'\r')
    time.sleep(0.05)
    if uart.any():
        response = uart.readline()
        if response:
            return response.decode('utf-8').strip()
    return None

def run_example():
    commands = ["r", "h0", "c01", "m"]  # stato di Bell

    for cmd in commands:
        print(f"Sending: {cmd}")
        led.on()
        resp = send_command(cmd)
        led.off()
        if resp:
            print("Response:", resp)
        else:
            print("No response received")
        time.sleep(0.1)


print("UART FPGA Controller")
print("Commands: r, h0, h1, c01, c10, m, e (export/sync), q to quit")
while True:
    user_input = input("> ").strip()
    if user_input.lower() == 'q':
        break
    if user_input in ["r", "h0", "h1", "c01", "c10", "m", "e"]:
        resp = send_command(user_input)
        print("quantum:", resp)
    else:
        print("Invalid command")

