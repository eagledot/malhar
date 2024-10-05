import os
from setuptools import setup


def get_long_description():
    # TODO:
    pass
    # with open(os.path.join(os.path.dirname(__file__), "README.rst"), encoding='utf-8') as fp:
    #     return fp.read()

setup(
    name='Malhar',
    version='0.0.1',
    description='Fuzzy Search Index',
    license='Apache 2.0',
    long_description=get_long_description(),
    author='Anubhav Nain',
    author_email='anubhav@eagledot.xyz',

    packages=['malhar'],
    include_package_data = True,
    python_requires=">=3.8",      # TODO: although no hard dependence on python version ! (may be type hints etc.)
    
    classifiers=[
        "License :: OSI Approved :: Apache 2.0",
        "Programming Language :: Python",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: Implementation :: CPython",
    ],
)