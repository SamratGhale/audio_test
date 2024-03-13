package main

import "core:fmt"
import "core:os"
import "core:c/libc"
import "core:strings"
import ma "vendor:miniaudio"

FORMAT      :: ma.format.f32 //must always be f32
CHANNELS    :: 2 
SAMPLE_RATE :: 48000

//effect properties

LPF_BIAS :: 0.9 //higher values means more bias towards low pass filter
//Lower values means bore bias towards the echo. Must be between 0 and 1

LPF_CUTOFF_FACTOR :: 80 //Hifh values = more filter
LPF_ORDER         :: 9
DELAY_IN_SECONDS  :: 0.2
DECAY             :: 0.5 //volume falloff for each echo


sound_node  :: struct{
	node    :  ma.data_source_node,
	/* If you make this the first member, you can pass a pointer to this struct into any ma_node_* API and it will "just work ". */
	decoder :  ma.decoder, 
}


node_graph    : ma.node_graph
lpf_node      : ma.lpf_node
delay_node    : ma.delay_node
splitter_node : ma.splitter_node
sound_nodes   : [dynamic]sound_node
node_count    : int

data_callback :: proc "c" (
	device : ^ma.device,
	output: rawptr,
	input: rawptr,
	frame_count: u32){

	ma.node_graph_read_pcm_frames(&node_graph, output, u64(frame_count), nil)
}

cleanup :: proc(){

	// Sounds
	for sounds in &sound_nodes{
		ma.data_source_node_uninit(&sounds.node, nil)
		ma.decoder_uninit(&sounds.decoder)
	}

	/* Splitter */
	ma.splitter_node_uninit(&splitter_node, nil)
	ma.delay_node_uninit(&delay_node, nil)
	ma.lpf_node_uninit(&lpf_node, nil)
	ma.node_graph_uninit(&node_graph, nil)
}


main :: proc(){

	iarg : int 
	result : ma.result

	//We'll set up our node starting from the end and working out way to the start. well need to set up the graph first

	{
		//initilize graph
		graph_config := ma.node_graph_config_init(CHANNELS)

		result = ma.node_graph_init(&graph_config, nil, &node_graph)

		if result != .SUCCESS{
			fmt.printf("ERROR: failed to initialize node graph. ")
			return
		}

	}
	//low pass filter
	{
		lpf_node_config := ma.lpf_node_config_init(CHANNELS, SAMPLE_RATE, SAMPLE_RATE/ LPF_CUTOFF_FACTOR, LPF_ORDER)

		result = ma.lpf_node_init(&node_graph, &lpf_node_config, nil, &lpf_node)

		if result != .SUCCESS{
			fmt.printf("ERROR: failed to initialize low pass filter node. ")
			return
		}

		//Connect the output bus of the low pass filter node to the input bus of the endpoint.
		ma.node_attach_output_bus(cast(^ma.node)&lpf_node, 0, ma.node_graph_get_endpoint(&node_graph),0)

		//Set the volume of the low pass filter to make it more of less impactful

		ma.node_set_output_bus_volume(cast(^ma.node)&lpf_node, 0, LPF_BIAS)
	}

	// Echo / delay
	{
		delay_node_config := ma.delay_node_config_init(CHANNELS, SAMPLE_RATE, u32(SAMPLE_RATE * DELAY_IN_SECONDS), DECAY)
		result      =ma.delay_node_init(&node_graph, &delay_node_config, nil, &delay_node)

		if result != .SUCCESS{

			fmt.printf("ERROR: failed to initilize delay node. err = %s", result)
			return
		}

		//Connect the ouput bus of the delay node to the input bus of the endpoint
		ma.node_attach_output_bus(cast(^ma.node)&delay_node, 0, ma.node_graph_get_endpoint(&node_graph), 0)
		ma.node_set_output_bus_volume(cast(^ma.node)&delay_node, 0, 1 - LPF_BIAS)
	}

	/* Splitter . */

	{
		splitter_node_config := ma.splitter_node_config_init(CHANNELS)
		result                = ma.splitter_node_init(&node_graph, &splitter_node_config, nil, &splitter_node)

		if result != .SUCCESS{
			fmt.printf("ERROR: failed to initilize splitter node.")
			return
		}

	}
	//Connect output buf 0 to the input bus of the low pass filter node, and output buf 1 to the input bus of the delay node
	ma.node_attach_output_bus(cast(^ma.node)&splitter_node, 0, cast(^ma.node)&lpf_node, 0)
	ma.node_attach_output_bus(cast(^ma.node)&splitter_node, 1, cast(^ma.node)&delay_node, 0)

	/* Data sources. Ignore any that cannot be loaded. */
	sound_nodes = make([dynamic]sound_node, len(os.args), len(os.args))

	
	for i in 1 ..< len(os.args)
	{
		decoder_config := ma.decoder_config_init(FORMAT, CHANNELS, SAMPLE_RATE)

		file_path := fmt.ctprintf("%s", os.args[i])
		result = ma.decoder_init_file(file_path, &decoder_config, &sound_nodes[i-1].decoder)

		if result == .SUCCESS{
			data_source_node_conifg := ma.data_source_node_config_init(cast(^ma.data_source)&sound_nodes[i-1].decoder)

			result = ma.data_source_node_init(&node_graph, &data_source_node_conifg, nil, &sound_nodes[i-1].node)

			if result == .SUCCESS{
				//Data souce has been created successfully
				ma.node_attach_output_bus(cast(^ma.node)&sound_nodes[i-1].node, 0, cast(^ma.node)&splitter_node, 0)
			}else{
				fmt.printf("Warning: Failed to init data souce node for sound \"%s\"", os.args[i])
			}
		}else{
			fmt.println("WARNING: Failed to load sound \"%s\"", os.args[i]) 
		}
	}

	//everything has been initialized successfully so we can set up a playback device so we can listen to the result


	{
		device_config : ma.device_config
		device        : ma.device

		device_config = ma.device_config_init(.playback)
		device_config.playback.format       = FORMAT
		device_config.playback.channels     = CHANNELS
		device_config.sampleRate            = SAMPLE_RATE
		device_config.dataCallback          = data_callback
		device_config.pUserData             = nil

		result = ma.device_init(nil, &device_config, &device)

		if result != .SUCCESS{
			fmt.printf("Failed to initilizage device.")
			cleanup()
		}

		result = ma.device_start(&device)

		if result != .SUCCESS{
			ma.device_uninit(&device)
			cleanup()
		}

		fmt.printf("Press enter to quit...\n")
		libc.getchar()
		ma.device_uninit(&device)
	}


	return
}










