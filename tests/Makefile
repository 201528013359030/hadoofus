HEADERS = \
		  ../include/lowlevel.h \
		  ../include/objects.h \
		  ../include/highlevel.h

LIB = ../src/libhadoofus.so

TEST_SRCS = \
			t_main.c \
			t_hl_rpc_basics.c

TEST_OBJS = $(TEST_SRCS:%.c=%.o)

TEST_PRGM = check_hadoofus

check: $(TEST_PRGM)
	LD_LIBRARY_PATH="$$LD_LIBRARY_PATH:../src" ./$(TEST_PRGM)

$(TEST_PRGM): $(TEST_OBJS) $(LIB) $(HEADERS) t_main.h
	gcc -Wall -fPIC -g $(CFLAGS) -o $@ $(TEST_OBJS) -lcheck -L../src -lhadoofus

%.o: %.c
	gcc -Wall -fPIC -g $(CFLAGS) -I../include -std=gnu99 -c $<

clean:
	rm -f $(TEST_PRGM) *.o