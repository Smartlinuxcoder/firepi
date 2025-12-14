TOP       = top
DEVICE    = up5k
PACKAGE   = sg48

all: $(TOP).bin

$(TOP).json: $(TOP).v
	yosys -p "synth_ice40 -top $(TOP) -json $(TOP).json" $(TOP).v

$(TOP).asc: $(TOP).json pins.pcf
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) \
	    --json $(TOP).json --pcf pins.pcf --asc $(TOP).asc

$(TOP).bin: $(TOP).asc
	icepack $(TOP).asc $(TOP).bin

yeet: $(TOP).bin
	sudo mpremote fs cp $(TOP).bin :

arson:
	rm -f *.json *.asc *.bin
