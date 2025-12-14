from machine import SPI, Pin
import time
import os


SCK_PIN = 2
MOSI_PIN = 3
MISO_PIN = 4
CS_PIN = 5
SPI_SPEED = 10_000_000 

BITSTREAM_FILE = "top.bin"

class W25Q16:
    
    CMD_WRITE_ENABLE = 0x06
    CMD_WRITE_DISABLE = 0x04
    CMD_READ_STATUS = 0x05
    CMD_READ_STATUS2 = 0x35
    CMD_WRITE_STATUS = 0x01
    CMD_READ_DATA = 0x03
    CMD_FAST_READ = 0x0B
    CMD_PAGE_PROGRAM = 0x02
    CMD_SECTOR_ERASE = 0x20
    CMD_BLOCK_ERASE_32K = 0x52
    CMD_BLOCK_ERASE_64K = 0xD8
    CMD_CHIP_ERASE = 0xC7
    CMD_READ_ID = 0x9F
    CMD_POWER_DOWN = 0xB9
    CMD_RELEASE_POWER_DOWN = 0xAB
    
    PAGE_SIZE = 256
    SECTOR_SIZE = 4096
    BLOCK_32K_SIZE = 32768
    BLOCK_64K_SIZE = 65536
    TOTAL_SIZE = 2 * 1024 * 1024  # 2MB
    
    def __init__(self, spi, cs_pin):
        self.spi = spi
        self.cs = Pin(cs_pin, Pin.OUT)
        self.cs.value(1)
        
    def _select(self):
        self.cs.value(0)
        time.sleep_us(1)
        
    def _deselect(self):
        time.sleep_us(1)
        self.cs.value(1)
        
    def read_id(self):
        self._select()
        self.spi.write(bytes([self.CMD_READ_ID]))
        id_data = self.spi.read(3)
        self._deselect()
        return id_data
    
    def _wait_ready(self, timeout_ms=5000):
        start = time.ticks_ms()
        while True:
            self._select()
            self.spi.write(bytes([self.CMD_READ_STATUS]))
            status = self.spi.read(1)[0]
            self._deselect()
            
            if not (status & 0x01):
                break
                
            if time.ticks_diff(time.ticks_ms(), start) > timeout_ms:
                raise TimeoutError("Flash busy timeout")
                
            time.sleep_ms(1)
    
    def _write_enable(self):
        self._select()
        self.spi.write(bytes([self.CMD_WRITE_ENABLE]))
        self._deselect()
    
    def _write_disable(self):
        self._select()
        self.spi.write(bytes([self.CMD_WRITE_DISABLE]))
        self._deselect()
    
    def read(self, address, length):
        self._wait_ready()
        self._select()
        self.spi.write(bytes([
            self.CMD_READ_DATA,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF
        ]))
        data = self.spi.read(length)
        self._deselect()
        return data
    
    def write_page(self, address, data):
        if len(data) > self.PAGE_SIZE:
            raise ValueError(f"Page write limited to {self.PAGE_SIZE} bytes")
        
        if len(data) == 0:
            return
        
        self._wait_ready()
        self._write_enable()
        
        self._select()
        self.spi.write(bytes([
            self.CMD_PAGE_PROGRAM,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF
        ]))
        self.spi.write(data)
        self._deselect()
        
        self._wait_ready()
    
    def erase_sector(self, address):
        self._wait_ready()
        self._write_enable()
        
        self._select()
        self.spi.write(bytes([
            self.CMD_SECTOR_ERASE,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF
        ]))
        self._deselect()
        
        self._wait_ready(timeout_ms=1000)
    
    def erase_block_64k(self, address):
        self._wait_ready()
        self._write_enable()
        
        self._select()
        self.spi.write(bytes([
            self.CMD_BLOCK_ERASE_64K,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF
        ]))
        self._deselect()
        
        self._wait_ready(timeout_ms=3000)
    
    def erase_chip(self):
        self._wait_ready()
        self._write_enable()
        
        self._select()
        self.spi.write(bytes([self.CMD_CHIP_ERASE]))
        self._deselect()
        
        self._wait_ready(timeout_ms=20000)


def print_progress_bar(current, total, width=40):
    percent = current / total
    filled = int(width * percent)
    bar = '█' * filled + '░' * (width - filled)
    print(f'\r[{bar}] {percent*100:.1f}% ({current}/{total})', end='')


def program_ice40(flash, bitstream_file):
   
    print("\n" + "=" * 60)
    print("iCE40 FPGA FLASH PROGRAMMER")
    print("=" * 60)
    
    try:
        file_size = os.stat(bitstream_file)[6]
        print(f"✓ Found bitstream: {bitstream_file}")
        print(f"✓ File size: {file_size} bytes ({file_size/1024:.2f} KB)")
    except OSError:
        print(f"✗ ERROR: File '{bitstream_file}' not found!")
        print("\nAvailable files:")
        for f in os.listdir():
            try:
                size = os.stat(f)[6]
                print(f"  {f} ({size} bytes)")
            except:
                print(f"  {f}")
        return False
    
    if file_size > flash.TOTAL_SIZE:
        print(f"✗ ERROR: Bitstream too large! ({file_size} > {flash.TOTAL_SIZE})")
        return False
    
    print("\n" + "-" * 60)
    print("Verifying flash connection...")
    try:
        chip_id = flash.read_id()
        print(f"✓ Flash ID: {chip_id.hex()} (Winbond W25Q16JV)")
    except Exception as e:
        print(f"✗ ERROR: Cannot communicate with flash: {e}")
        return False
    
    print("\n" + "-" * 60)
    print(f"Reading {bitstream_file}...")
    try:
        with open(bitstream_file, 'rb') as f:
            bitstream = f.read()
        print(f"✓ Read {len(bitstream)} bytes")
    except Exception as e:
        print(f"✗ ERROR reading file: {e}")
        return False
    
    sectors_needed = (len(bitstream) + flash.SECTOR_SIZE - 1) // flash.SECTOR_SIZE
    blocks_64k = (len(bitstream) + flash.BLOCK_64K_SIZE - 1) // flash.BLOCK_64K_SIZE
    
    print(f"  Memory required: {sectors_needed} sectors ({sectors_needed * 4} KB)")
    print(f"  Using {blocks_64k} x 64KB block erase(s) for speed")
    
    print("\n" + "-" * 60)
    print("Erasing flash...")
    start_time = time.ticks_ms()
    
    try:
        for block in range(blocks_64k):
            address = block * flash.BLOCK_64K_SIZE
            print(f"  Erasing block at 0x{address:06X} ({block+1}/{blocks_64k})...")
            flash.erase_block_64k(address)
        
        remainder_start = blocks_64k * flash.BLOCK_64K_SIZE
        if remainder_start < len(bitstream):
            remaining_sectors = (len(bitstream) - remainder_start + flash.SECTOR_SIZE - 1) // flash.SECTOR_SIZE
            for sector in range(remaining_sectors):
                address = remainder_start + (sector * flash.SECTOR_SIZE)
                flash.erase_sector(address)
        
        erase_time = time.ticks_diff(time.ticks_ms(), start_time)
        print(f"✓ Erase complete ({erase_time/1000:.2f}s)")
        
    except Exception as e:
        print(f"✗ ERROR during erase: {e}")
        return False
    
    print("\n" + "-" * 60)
    print("Programming flash...")
    start_time = time.ticks_ms()
    
    try:
        total_pages = (len(bitstream) + flash.PAGE_SIZE - 1) // flash.PAGE_SIZE
        
        for page_num in range(total_pages):
            address = page_num * flash.PAGE_SIZE
            end_addr = min(address + flash.PAGE_SIZE, len(bitstream))
            chunk = bitstream[address:end_addr]
            
            flash.write_page(address, chunk)
            
            if page_num % 16 == 0 or page_num == total_pages - 1:
                print_progress_bar(page_num + 1, total_pages)
        
        print()  # New line after progress bar
        program_time = time.ticks_diff(time.ticks_ms(), start_time)
        speed = len(bitstream) / (program_time / 1000)
        print(f"✓ Programming complete ({program_time/1000:.2f}s, {speed:.0f} bytes/s)")
        
    except Exception as e:
        print(f"\n✗ ERROR during programming: {e}")
        return False
    
    # Verify
    print("\n" + "-" * 60)
    print("Verifying...")
    start_time = time.ticks_ms()
    
    try:
        VERIFY_CHUNK = 4096
        errors = 0
        
        for offset in range(0, len(bitstream), VERIFY_CHUNK):
            chunk_size = min(VERIFY_CHUNK, len(bitstream) - offset)
            written_data = bitstream[offset:offset + chunk_size]
            read_data = flash.read(offset, chunk_size)
            
            if written_data != read_data:
                errors += 1
                print(f"\n✗ Verification error at 0x{offset:06X}!")
                print(f"  Expected: {written_data[:16].hex()}...")
                print(f"  Read:     {read_data[:16].hex()}...")
                if errors >= 5:
                    print("✗ Too many errors, stopping verification")
                    return False
            
            if offset % (16 * 1024) == 0:
                print_progress_bar(offset + chunk_size, len(bitstream))
        
        print()
        
        if errors == 0:
            verify_time = time.ticks_diff(time.ticks_ms(), start_time)
            print(f"✓ Verification successful! ({verify_time/1000:.2f}s)")
        else:
            print(f"✗ Verification failed with {errors} error(s)")
            return False
            
    except Exception as e:
        print(f"\n✗ ERROR during verification: {e}")
        return False
    
    total_time = time.ticks_diff(time.ticks_ms(), start_time)
    print("\n" + "=" * 60)
    print("SUCCESS! iCE40 FPGA programmed successfully!")
    print("=" * 60)
    print(f"Total time: {total_time/1000:.2f}s")
    print("\nYour iCE40 FPGA should now boot with the new bitstream.")
    print("Power cycle your board to load the configuration.")
    
    return True


def main():
    print("\narson FPGA Flash Programmer")
    print("Starting in 2 seconds...\n")
    time.sleep(2)
    
    try:
        spi = SPI(0,
                  baudrate=SPI_SPEED,
                  polarity=0,
                  phase=0,
                  sck=Pin(SCK_PIN),
                  mosi=Pin(MOSI_PIN),
                  miso=Pin(MISO_PIN))
        flash = W25Q16(spi, CS_PIN)
    except Exception as e:
        print(f"ERROR: Failed to initialize SPI: {e}")
        return
    
    success = program_ice40(flash, BITSTREAM_FILE)
    
    if not success:
        print("\n" + "=" * 60)
        print("PROGRAMMING FAILED")
        print("=" * 60)
        print("Please check the errors above and try again.")


if __name__ == "__main__":
    main()
